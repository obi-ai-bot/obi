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
        VStack(alignment: .leading, spacing: 0) {
            if let receipt = Self.receipt(record) { Receipt(text: receipt, expanded: $expanded) }
            if record.done == nil || expanded {
                AskCard(kind: "Permission", title: record.permission.title, detail: record.permission.detail,
                        options: CardOption.permission(record.permission), busy: busy || record.done != nil, answered: record.done != nil,
                        keyboardEnabled: keyboardEnabled && record.done == nil, focusRequest: focusRequest,
                        hint: record.done == nil && onTell != nil ? "No, and tell the agent what to do differently" : nil, onHint: onTell,
                        onChoose: { option in
                            if let decision = RunnerPermission.Decision(rawValue: option.answer) { answer(decision) }
                        },
                        onLater: record.done == nil ? { feed.laterPermission(record.id) } : nil)
                    .padding(.top, record.done == nil ? 0 : 12)
            }
            if let problem { Text(problem).font(Tokens.font(Tokens.textSm)).foregroundStyle(Tokens.danger).padding(.top, 8) }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tokens.chip, in: RoundedRectangle(cornerRadius: Tokens.askRadius, style: .continuous))
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
