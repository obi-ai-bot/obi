import SwiftUI

/// The exact command/rule remains visible, and only a confirmed response becomes a receipt.
struct InlinePermission: View {
    let record: RunnerFeed.PermissionRecord
    let feed: RunnerFeed
    var keyboardEnabled = false
    var focusRequest = 0
    var onTell: (() -> Void)? = nil
    @State private var expanded = false
    @State private var busy = false
    @State private var problem: String?

    static func receipt(_ record: RunnerFeed.PermissionRecord) -> String? {
        guard let done = record.done, let answer = InboxWords.plain(record.answer) else { return nil }
        let subject = InboxWords.plain(record.permission.detail) ?? record.permission.title
        return "\(answer): \(subject) · \(ConversationModel.clock(done))"
    }

    @ViewBuilder var body: some View {
        if record.done == nil || Self.receipt(record) != nil { card }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: OBYStyle.Space.sm) {
            if let receipt = Self.receipt(record) {
                Button { expanded.toggle() } label: {
                    Label(receipt, systemImage: "checkmark.circle.fill")
                        .font(OBYStyle.caption).foregroundStyle(OBYStyle.secondary)
                }
                .buttonStyle(.plain)
            }
            if record.done == nil || expanded {
                DecisionCard(title: record.permission.title, detail: record.permission.detail,
                             options: CardOption.permission(record.permission), busy: busy || record.done != nil,
                             keyboardEnabled: keyboardEnabled && record.done == nil, focusRequest: focusRequest,
                             onLater: record.done == nil ? { feed.laterPermission(record.id) } : nil,
                             wordsNote: CardOption.denyWords,
                             onChoose: { option in
                                 if let decision = RunnerPermission.Decision(rawValue: option.answer) { answer(decision) }
                             }, onWords: { answer(.deny, note: $0) })
            }
            if record.done == nil, let onTell {
                Button("No, and tell the agent what to do differently", action: onTell)
                    .buttonStyle(.plain).font(OBYStyle.caption).disabled(busy)
            }
            if let problem { Text(problem).font(OBYStyle.caption).foregroundStyle(.red) }
        }
        .padding(OBYStyle.Space.lg)
        .frame(maxWidth: OBYStyle.replyWidth, alignment: .leading)
        .background(OBYStyle.surface, in: RoundedRectangle(cornerRadius: OBYStyle.card))
    }

    private func answer(_ decision: RunnerPermission.Decision, note: String? = nil) {
        guard !busy, record.done == nil,
              feed.extras[record.job]?.permission?.id == record.permission.id else { return }
        busy = true
        problem = nil
        Task {
            defer { busy = false }
            do { try await feed.answer(record.job, decision, message: note) }
            catch { problem = error.localizedDescription }
        }
    }
}
