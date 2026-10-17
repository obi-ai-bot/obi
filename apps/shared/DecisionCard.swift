import SwiftUI

/// The card: what's asked (Oby's headline, when it wrote one, and what happened), the command or
/// file it's about, the plan, the options with the recommended one first (and why), then "Type
/// your own…". The asker's own words wait behind Details when a headline stands in for them. One
/// tap answers. Its container adds the background and what goes around it (Later, Done, Open job).
struct DecisionCard: View {
    let title: String
    /// What happened, in a sentence or two, under the title.
    var happened: String? = nil
    /// The item's own text, behind Details, when the title is Oby's headline instead.
    var behindDetails: String? = nil
    /// The command or the file a permission is about.
    var detail: String? = nil
    /// A plan to approve, in markdown.
    var plan: String? = nil
    let options: [CardOption]
    var busy = false
    var keyboardEnabled = false
    var focusRequest = 0
    var onLater: (() -> Void)? = nil
    /// What sending your own words does, when it isn't plain (a permission's: they go with a deny).
    var wordsNote: String? = nil
    let onChoose: (CardOption) -> Void
    /// Sends the user's own words as the answer; nil where words can't answer it.
    var onWords: ((String) -> Void)? = nil

    @State private var chosen: String?
    @State private var typing = false
    @State private var showsDetails = false
    @State private var words = ""
    @FocusState private var focused: Bool
    @FocusState private var cardFocused: Bool
    /// Dynamic Type's scale, for the plan's inline code.
    @ScaledMetric(relativeTo: .body) private var scale: CGFloat = 1

    private var typed: String { words.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: Style.spacing) {
            HStack(alignment: .top) {
                ReadingText(title, weight: .semibold)
                Spacer(minLength: OBYStyle.Space.sm)
                if let onLater {
                    Button(action: onLater) { Image(systemName: "xmark") }
                        .buttonStyle(.plain).foregroundStyle(Style.secondary)
                        .help("Later (Esc)").accessibilityLabel("Later")
                }
            }
            if let happened, !happened.isEmpty {
                ReadingText(happened)
            }
            if let detail, !detail.isEmpty {
                Text(detail).readingCode()
                    .selectable()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Style.inset)
                    .background(Style.fill.opacity(0.6), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            if let plan, !plan.isEmpty { planView(plan) }
            if let behindDetails, !behindDetails.isEmpty { details(behindDetails) }
            ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                button(option, index: index)
            }
            if let onWords { ownWords(onWords) }
        }
        .disabled(busy)
        #if os(macOS)
        .focusable().focusEffectDisabled().focused($cardFocused)
        // Only an explicit jump/click gives a card the keyboard; arrival must never interrupt typing.
        .onTapGesture { if keyboardEnabled && !focused { cardFocused = true } }
        .onExitCommand { if keyboardEnabled && !busy { onLater?() } }
        .onChange(of: focusRequest) { if keyboardEnabled { cardFocused = true } }
        .onKeyPress(phases: .down) { press in
            guard keyboardEnabled, cardFocused, !focused, press.modifiers.isEmpty else { return .ignored }
            let key = press.key == .return ? "return" : press.key == .escape ? "escape" : press.characters
            switch DecisionKey.action(key, options: options, words: words, busy: busy) {
            case .option(let option): choose(option)
            case .words(let text): onWords?(text)
            case .later: onLater?()
            case .none: return .ignored
            }
            return .handled
        }
        #endif
    }

    private func choose(_ option: CardOption) {
        guard !busy else { return }
        chosen = option.answer
        onChoose(option)
    }

    // MARK: Details

    @ViewBuilder private func details(_ text: String) -> some View {
        Button { showsDetails.toggle() } label: {
            Label("Details", systemImage: showsDetails ? "chevron.down" : "chevron.right")
                .font(Style.small.weight(.semibold)).foregroundStyle(Style.secondary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(showsDetails ? "Shown" : "Hidden")
        if showsDetails {
            ReadingText(text, secondary: true).selectable()
        }
    }

    // MARK: The plan

    @ViewBuilder private func planView(_ plan: String) -> some View {
        let text = VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(PlanBlock.blocks(plan).enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let text): Text(inline(text)).fontWeight(.semibold)
                case .item(let marker, let text):
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(marker).foregroundStyle(Style.secondary)
                        Text(inline(text))
                    }
                case .code(let text): Text(text).readingCode()
                case .text(let text): Text(inline(text))
                }
            }
        }
        .readingText()
        .selectable()
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Style.inset)
        #if os(watchOS)
        // The watch's screen scrolls already: the plan goes in line.
        text.background(Style.fill.opacity(0.6), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        #else
        ScrollView { text }
            .frame(maxHeight: Style.planHeight)
            .fixedSize(horizontal: false, vertical: true)
            .background(Style.fill.opacity(0.6), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        #endif
    }

    // MARK: Options

    @ViewBuilder private func button(_ option: CardOption, index: Int) -> some View {
        #if os(watchOS)
        Button { choose(option) } label: {
            VStack(alignment: .leading, spacing: 1) {
                if option.recommended { Text("Recommended").font(.caption2.weight(.semibold)).foregroundStyle(.secondary) }
                ReadingText(option.label)
                if let detail = option.detail { Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(3) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .tint(Self.tint(option))
        .accessibilityHint(Self.hint(option))
        #else
        Button { choose(option) } label: {
            HStack(alignment: .firstTextBaseline, spacing: OBYStyle.Space.sm) {
                Text("\(index + 1)").font(Style.small.weight(.semibold))
                    .foregroundStyle(Style.secondary).frame(width: 20)
                if busy && chosen == option.answer { ProgressView().controlSize(.small) }
                VStack(alignment: .leading, spacing: 2) {
                    if option.role == .destructive {
                        Text(option.label).font(Reading.current.prose).fontWeight(.medium).foregroundStyle(Color.red)
                    } else {
                        ReadingText(option.label, weight: .medium)
                    }
                    if let detail = option.detail {
                        Text(detail).font(Style.small).foregroundStyle(Style.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                if option.recommended {
                    Text("Recommended").font(Style.small.weight(.semibold)).foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.18), in: Capsule())
                }
            }
            .padding(.horizontal, Style.optionPadding).padding(.vertical, Style.optionHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Style.fill.opacity(option.recommended ? 1.6 : 1), in: RoundedRectangle(cornerRadius: OBYStyle.card, style: .continuous))
            .overlay {
                if option.recommended {
                    RoundedRectangle(cornerRadius: OBYStyle.card, style: .continuous).strokeBorder(Color.accentColor.opacity(0.6), lineWidth: 1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint(Self.hint(option))
        #endif
    }

    /// Bold, italics, code and links in a line of the plan, as the reading style sets them (apps/shared/ReadingText.swift).
    private func inline(_ text: String) -> AttributedString {
        let reading = Reading.current
        return Reading.markdown(text, code: reading.code(scale: reading.style == nil ? 1 : scale))
    }

    private static func hint(_ option: CardOption) -> String { option.recommended ? "Recommended" : "" }

    #if os(watchOS)
    private static func tint(_ option: CardOption) -> Color? {
        if option.recommended { return .accentColor }
        return option.role == .destructive ? .red : nil
    }
    #endif

    // MARK: Your own words

    @ViewBuilder private func ownWords(_ send: @escaping (String) -> Void) -> some View {
        #if os(watchOS)
        // Tap, then dictate (or scribble): what comes back is the answer.
        TextFieldLink(prompt: Text("Type your own answer")) {
            Label("Type your own answer", systemImage: "mic")
        } onSubmit: { text in
            let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard (1...2000).contains(text.count) else { return }
            send(text)
        }
        if let wordsNote { Text(wordsNote).font(.caption2).foregroundStyle(.secondary) }
        #elseif os(macOS)
        // The keyboard is right there: the line is open from the start.
        field(send)
        if let wordsNote { Text(wordsNote).font(Style.small).foregroundStyle(Style.secondary) }
        #else
        if typing {
            // The keyboard's mic dictates into it.
            field(send).onAppear { focused = true }
            if let wordsNote { Text(wordsNote).font(Style.small).foregroundStyle(Style.secondary) }
        } else {
            Button { typing = true } label: {
                Label("Type your own answer", systemImage: "keyboard")
                    .font(Style.option).foregroundStyle(Style.secondary)
                    .padding(.horizontal, Style.optionPadding).padding(.vertical, Style.optionHeight)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Style.fill.opacity(0.6), in: RoundedRectangle(cornerRadius: OBYStyle.card, style: .continuous))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Answer in your own words, typed or dictated")
        }
        #endif
    }

    #if !os(watchOS)
    private func field(_ send: @escaping (String) -> Void) -> some View {
        let go = {
            guard (1...2000).contains(typed.count) else { return }
            send(typed)
        }
        return HStack(spacing: 8) {
            TextField("Type your own answer", text: $words, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...4)
                .readingText()
                .focused($focused)
                .submitLabel(.send)
                .onSubmit(go)
                #if os(macOS)
                .onKeyPress(.return, phases: .down) { press in
                    if press.modifiers.contains(.shift) { return .ignored }
                    go()
                    return .handled
                }
                #endif
            Button(action: go) {
                Image(systemName: "arrow.up").font(Style.small.weight(.bold))
                    .foregroundStyle(Style.paper)
                    .frame(width: 26, height: 26)
                    .background(Style.ink.opacity(typed.isEmpty ? 0.4 : 1), in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(typed.isEmpty || typed.count > 2000)
            .accessibilityLabel("Answer")
        }
        .padding(.leading, Style.optionPadding).padding(.trailing, 5).padding(.vertical, 5)
        .background(Style.fill.opacity(0.75), in: RoundedRectangle(cornerRadius: 17, style: .continuous))
    }
    #endif

    /// Each app's look around the text: the Mac's window is dark, the iPhone follows the system.
    /// Long text itself takes the reading style (apps/shared/ReadingText.swift).
    private enum Style {
        #if os(macOS)
        static let ink = OBYStyle.primary
        static let paper = Color.black
        static let secondary = OBYStyle.secondary
        static let fill = OBYStyle.surface
        static let option = Font.system(size: 13, weight: .medium)
        static let small = OBYStyle.caption
        static let planHeight: CGFloat = 220
        static let spacing: CGFloat = 8
        static let inset: CGFloat = 10
        static let optionPadding: CGFloat = 14
        static let optionHeight: CGFloat = 9
        #elseif os(watchOS)
        static let secondary = Color.secondary
        static let fill = Color.primary.opacity(0.12)
        static let small = Font.caption2
        static let spacing: CGFloat = 6
        static let inset: CGFloat = 6
        #else
        static let ink = Color.primary
        static let paper = Color(uiColor: .systemBackground)
        static let secondary = Color.secondary
        static let fill = Color.primary.opacity(0.08)
        static let option = Font.subheadline.weight(.medium)
        static let small = Font.caption
        static let planHeight: CGFloat = 280
        static let spacing: CGFloat = 10
        static let inset: CGFloat = 12
        static let optionPadding: CGFloat = 16
        static let optionHeight: CGFloat = 12
        #endif
    }
}

private extension View {
    /// Text the user can select and copy, where the platform has it.
    @ViewBuilder func selectable() -> some View {
        #if os(watchOS)
        self
        #else
        textSelection(.enabled)
        #endif
    }
}
