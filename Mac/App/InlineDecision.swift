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

    private var card: some View {
        VStack(alignment: .leading, spacing: OBYStyle.Space.sm) {
            if let receipt = Self.receipt(item, permission: permission) {
                Button { expanded.toggle() } label: {
                    Label(receipt,
                          systemImage: "checkmark.circle.fill")
                        .font(OBYStyle.caption).foregroundStyle(OBYStyle.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain).accessibilityValue(expanded ? "Expanded" : "Collapsed")
            }
            if !settled || expanded {
                Text(item.title).font(OBYStyle.caption).foregroundStyle(OBYStyle.tertiary)
                DecisionCard(title: words.title(item.text), happened: words.body, behindDetails: words.details(item.text),
                             detail: permission?.detail, plan: question?.plan,
                             options: CardOption.inbox(item.options, kind: "\(item.kind)", question: question,
                                                       permission: permission, words: words, details: item.details),
                             busy: busy || settled, keyboardEnabled: keyboardEnabled && !settled, focusRequest: focusRequest,
                             onLater: settled ? nil : { answer(later: .now.addingTimeInterval(3600)) },
                             wordsNote: item.kind == .permission ? CardOption.denyWords : nil,
                             onChoose: { answer($0.answer) },
                             onWords: item.kind.takesWords ? { answer($0) } : nil)
                if !settled, item.kind.takesWords, let onTell {
                    Button("Tell it instead", action: onTell).buttonStyle(.plain).font(OBYStyle.caption).disabled(busy)
                }
                if !item.job.isEmpty {
                    Button("Open job") { onOpen(item.job, entry.local) }.buttonStyle(.plain).font(OBYStyle.caption)
                }
            }
            if let problem { Text(problem).font(OBYStyle.caption).foregroundStyle(.red) }
        }
        .padding(OBYStyle.Space.lg)
        .frame(maxWidth: OBYStyle.replyWidth, alignment: .leading)
        .background(OBYStyle.surface, in: RoundedRectangle(cornerRadius: OBYStyle.card))
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
