import SwiftUI

/// The card: what's asked, the command or file it's about, the plan, the options with the
/// recommended one first, then "Type your own…". One tap answers. Its container adds the
/// background and what goes around it (Later, Done, Open job).
struct DecisionCard: View {
    let title: String
    /// The command or the file a permission is about.
    var detail: String? = nil
    /// A plan to approve, in markdown.
    var plan: String? = nil
    let options: [CardOption]
    var busy = false
    /// What sending your own words does, when it isn't plain (a permission's: they go with a deny).
    var wordsNote: String? = nil
    let onChoose: (CardOption) -> Void
    /// Sends the user's own words as the answer; nil where words can't answer it.
    var onWords: ((String) -> Void)? = nil

    @State private var typing = false
    @State private var words = ""
    @FocusState private var focused: Bool

    private var typed: String { words.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: Style.spacing) {
            Text(title).font(Style.title).fixedSize(horizontal: false, vertical: true)
            if let detail, !detail.isEmpty {
                Text(detail).font(Style.code).foregroundStyle(Style.secondary)
                    .selectable()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Style.inset)
                    .background(Style.fill.opacity(0.6), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            if let plan, !plan.isEmpty { planView(plan) }
            ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                button(option, index: index)
            }
            if let onWords { ownWords(onWords) }
        }
        .disabled(busy)
    }

    // MARK: The plan

    @ViewBuilder private func planView(_ plan: String) -> some View {
        let text = VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(PlanBlock.blocks(plan).enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let text): Text(Self.inline(text)).font(Style.planHeading)
                case .item(let marker, let text):
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(marker).foregroundStyle(Style.secondary)
                        Text(Self.inline(text))
                    }
                case .code(let text): Text(text).font(Style.code)
                case .text(let text): Text(Self.inline(text))
                }
            }
        }
        .font(Style.plan)
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
        Button { onChoose(option) } label: {
            VStack(alignment: .leading, spacing: 1) {
                if option.recommended { Text("Recommended").font(.caption2.weight(.semibold)).foregroundStyle(.secondary) }
                Text(option.label).fixedSize(horizontal: false, vertical: true)
                if let detail = option.detail { Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(3) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .tint(Self.tint(option))
        .accessibilityHint(Self.hint(option))
        #else
        Button { onChoose(option) } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.label).font(Style.option)
                        .foregroundStyle(option.role == .destructive ? Color.red : Style.ink)
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
                #if os(macOS)
                Text("⌘\(index + 1)").font(Style.small).foregroundStyle(Style.secondary)
                #endif
            }
            .padding(.horizontal, Style.optionPadding).padding(.vertical, Style.optionHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Style.fill.opacity(option.recommended ? 1.6 : 1), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            .overlay {
                if option.recommended {
                    RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(Color.accentColor.opacity(0.6), lineWidth: 1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint(Self.hint(option))
        #if os(macOS)
        .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
        #endif
        #endif
    }

    /// Bold, italics, code and links in a line of the plan.
    private static func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
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
        TextFieldLink(prompt: Text("Type your own…")) {
            Label("Type your own…", systemImage: "mic")
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
                Label("Type your own…", systemImage: "keyboard")
                    .font(Style.option).foregroundStyle(Style.secondary)
                    .padding(.horizontal, Style.optionPadding).padding(.vertical, Style.optionHeight)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Style.fill.opacity(0.6), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
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
            TextField("Type your own…", text: $words, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...4)
                .font(Style.option)
                .focused($focused)
                .submitLabel(.send)
                .onSubmit(go)
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

    /// Each app's look: the Mac's island is dark with its own sizes, the iPhone follows the system.
    private enum Style {
        #if os(macOS)
        static let ink = Color.white
        static let paper = Color.black
        static let secondary = Color.white.opacity(0.55)
        static let fill = Color.white.opacity(0.09)
        static let title = Font.system(size: 15, weight: .semibold)
        static let option = Font.system(size: 13, weight: .medium)
        static let small = Font.system(size: 11)
        static let code = Font.system(size: 12).monospaced()
        static let plan = Font.system(size: 13)
        static let planHeading = Font.system(size: 13, weight: .semibold)
        static let planHeight: CGFloat = 220
        static let spacing: CGFloat = 8
        static let inset: CGFloat = 10
        static let optionPadding: CGFloat = 14
        static let optionHeight: CGFloat = 9
        #elseif os(watchOS)
        static let secondary = Color.secondary
        static let fill = Color.primary.opacity(0.12)
        static let title = Font.footnote.weight(.semibold)
        static let code = Font.caption2.monospaced()
        static let plan = Font.caption2
        static let planHeading = Font.caption.weight(.semibold)
        static let spacing: CGFloat = 6
        static let inset: CGFloat = 6
        #else
        static let ink = Color.primary
        static let paper = Color(uiColor: .systemBackground)
        static let secondary = Color.secondary
        static let fill = Color.primary.opacity(0.08)
        static let title = Font.headline
        static let option = Font.subheadline.weight(.medium)
        static let small = Font.caption
        static let code = Font.footnote.monospaced()
        static let plan = Font.subheadline
        static let planHeading = Font.subheadline.weight(.semibold)
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
