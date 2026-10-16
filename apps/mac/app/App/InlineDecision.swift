import SwiftUI

/// Answers stay pending until the desk/runner confirms them. The shared inbox record is the receipt,
/// including when another device answered; no optimistic result is stored in the view.
struct InlineDecision: View {
    let entry: IslandInbox.Entry
    let desk: Desk
    let feed: RunnerFeed
    var keyboardEnabled = false
    var focusRequest = 0
    var onOpen: (_ job: String, _ local: Bool) -> Void = { _, _ in }
    var onTell: (() -> Void)? = nil
    @State private var expanded = false
    @State private var busy = false
    @State private var problem: String?
    @State private var questionSnapshot: Question?
    @State private var permissionSnapshot: RunnerPermission?

    private var item: InboxItem { entry.item }
    private var settled: Bool { item.done != nil }
    private var words: InboxWords {
        entry.local ? InboxWords(headline: item.headline, happened: item.happened, recommended: item.recommended, why: item.why)
            : feed.inboxWords[item.id] ?? InboxWords()
    }
    private var extras: RunnerJobExtras? { entry.local ? nil : feed.extras[item.job] }

    private var livePermission: RunnerPermission? {
        guard item.kind == .permission else { return nil }
        if entry.local, let permission = desk.jobs.first(where: { $0.id == item.job })?.permission {
            return RunnerPermission(id: permission.id, tool: permission.tool, title: permission.title,
                                    detail: permission.detail, rule: permission.rule, always: permission.always)
        }
        return extras?.permission
    }
    private var permission: RunnerPermission? { livePermission ?? permissionSnapshot }

    private var liveQuestion: Question? {
        extras?.question ?? desk.jobs.first { entry.local && $0.id == item.job }?.question.map {
            Question(text: $0.text, options: $0.options, details: $0.details, recommended: $0.recommended)
        }
    }

    private var question: Question? { liveQuestion ?? questionSnapshot }
    static func receipt(_ item: InboxItem, permission: RunnerPermission? = nil) -> String? {
        guard let done = item.done, let answer = InboxWords.plain(item.answer) else { return nil }
        if item.kind == .permission {
            let subject = InboxWords.plain(permission?.detail) ?? permission?.title ?? item.text
            let choice: String = switch Inbox.decision(answer).0 {
            case .allow: "Allowed once"
            case .always: "Always allowed"
            case .deny: "Denied"
            }
            return "\(choice): \(subject) · \(ConversationModel.clock(done))"
        }
        return "You chose: \(answer) · \(ConversationModel.clock(done))"
    }

    @ViewBuilder var body: some View {
        if !settled || Self.receipt(item, permission: permission) != nil { card }
    }

    /// Sangam's decision in a conversation: a card of its own, its kind over Oby's headline, what
    /// happened, the command or plan it's about, the choices; answered, one line that opens it again.
    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let receipt = Self.receipt(item, permission: permission) {
                Receipt(text: receipt, expanded: $expanded)
            }
            if !settled || expanded {
                AskCard(kind: AskKind.label("\(item.kind)", plan: question?.plan != nil), failed: AskKind.failed("\(item.kind)"),
                        source: item.title, title: words.title(item.text), happened: words.body,
                        behindDetails: words.details(item.text), detail: permission?.detail, plan: question?.plan,
                        options: CardOption.inbox(item.options, kind: "\(item.kind)", question: question,
                                                  permission: permission, words: words, details: item.details),
                        busy: busy || settled, answered: settled, keyboardEnabled: keyboardEnabled && !settled, focusRequest: focusRequest,
                        hint: !settled && item.kind.takesWords && onTell != nil
                            ? (item.kind == .permission ? "No, and tell the agent what to do differently" : "Answer in your own words…") : nil,
                        onHint: item.kind.takesWords ? onTell : nil,
                        onChoose: { answer($0.answer) },
                        onLater: settled ? nil : { answer(later: .now.addingTimeInterval(3600)) },
                        onOpen: item.job.isEmpty ? nil : { onOpen(item.job, entry.local) })
                    .padding(.top, settled ? 12 : 0)
            }
            if let problem { Text(problem).font(Tokens.font(Tokens.textSm)).foregroundStyle(Tokens.danger).padding(.top, 8) }
        }
        .padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tokens.chip, in: RoundedRectangle(cornerRadius: Tokens.askRadius, style: .continuous))
        .onChange(of: livePermission, initial: true) {
            if !settled, let livePermission { permissionSnapshot = livePermission }
        }
        .onChange(of: liveQuestion, initial: true) {
            if !settled, let liveQuestion { questionSnapshot = liveQuestion }
        }
    }

    private func answer(_ value: String? = nil, later: Date? = nil) {
        guard !busy, !settled else { return }
        busy = true
        problem = nil
        Task {
            defer { busy = false }
            do {
                if entry.local {
                    try await desk.answer(item.id, value.map { .answer($0) } ?? .later(later ?? .now))
                } else {
                    try await feed.settle(item.id, answer: value, later: later)
                }
            } catch { problem = error.localizedDescription }
        }
    }
}

/// An answered decision, as it stays in the conversation: a check and what was chosen, when; a
/// click opens the card again.
struct Receipt: View {
    let text: String
    @Binding var expanded: Bool

    var body: some View {
        Button { withAnimation(Tokens.warm) { expanded.toggle() } } label: {
            HStack(spacing: 6) {
                Image(systemName: "checkmark").font(Tokens.font(11, .semibold))
                Text(text).font(Tokens.font(Tokens.textMd)).fadeOut()
                Image(systemName: "chevron.down").font(Tokens.font(9, .semibold)).rotationEffect(.degrees(expanded ? 180 : 0))
            }
            .foregroundStyle(Tokens.muted)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(expanded ? "Expanded" : "Collapsed")
    }
}

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
    let onChoose: (CardOption) -> Void
    var onLater: (() -> Void)? = nil
    var onOpen: (() -> Void)? = nil
    @State private var picked: String?
    @State private var showsDetails = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text(kind).font(Tokens.font(Tokens.textSm, .medium)).foregroundStyle(failed ? Tokens.danger : Tokens.needs)
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
                let explained = options.filter { $0.detail != nil || $0.recommended }
                if !explained.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(explained.enumerated()), id: \.offset) { _, option in
                            (Text(option.label).foregroundStyle(Tokens.text)
                                + Text(option.recommended ? " · Recommended" : "").foregroundStyle(Tokens.needs)
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
            .background(Color.black.opacity(0.3), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .padding(.top, 10)
    }
}

/// One choice: a pill, filled in ink for the recommended one, red words for a destructive one, no
/// fill for Later; its number (1 to 4) is its key.
private struct OptionPill: View {
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
            .foregroundStyle(primary ? Color(hex: 0x111111) : option.role == .destructive ? Tokens.danger : quiet ? (hovering ? Tokens.ink : Tokens.muted) : hovering ? Tokens.ink : Tokens.item)
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
private struct PlanText: View {
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
                            .background(Color.black.opacity(0.3), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
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
        .background(Color.black.opacity(0.3), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func inline(_ text: String) -> AttributedString { Reading.markdown(text, code: Tokens.mono(12)) }
}

/// A click gives a card the keyboard, where it takes keys; else the click goes past it (a task's
/// card opens its page).
private struct TapForKeys: ViewModifier {
    let enabled: Bool
    let action: () -> Void

    func body(content: Content) -> some View {
        if enabled { content.onTapGesture(perform: action) } else { content }
    }
}
