import SwiftUI

/// The exact command/rule remains visible, and only a confirmed response becomes a receipt.
struct InlinePermission: View {
    let record: RunnerFeed.PermissionRecord
    let feed: RunnerFeed
    var keyboardEnabled = false
    var focusRequest = 0
    @State private var expanded = false
    @State private var busy = false
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: OBYStyle.Space.sm) {
            if let done = record.done {
                Button { expanded.toggle() } label: {
                    Label("\(record.answer ?? "Answered on another device") · \(ConversationModel.clock(done))", systemImage: "checkmark.circle.fill")
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
