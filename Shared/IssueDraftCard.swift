import SwiftUI

/// A proposal card whose only outgoing action is an explicit Create issue tap.
struct IssueDraftCard: View {
    let draft: RunnerIssueDraft
    var keyboardEnabled = false
    var onCreate: () -> Void
    var onEdit: () -> Void
    var onDiscard: () -> Void

    nonisolated static func title(for draft: RunnerIssueDraft) -> String {
        switch draft.state {
        case .draft: "\(draft.fields.title) · \(draft.fields.repo) · Draft v\(draft.version)"
        case .creating: "\(draft.fields.title) · \(draft.fields.repo) · Creating…"
        case .created: "\(draft.fields.repo) · Created #\(draft.issue ?? 0)"
        case .failed: "\(draft.fields.title) · \(draft.fields.repo) · Failed: \(draft.error ?? "GitHub couldn't create the issue")"
        case .discarded: "\(draft.fields.repo) · Discarded"
        }
    }

    nonisolated static func options(for draft: RunnerIssueDraft) -> [CardOption] {
        guard draft.state != .created, draft.state != .discarded else { return [] }
        return [CardOption(label: "Create issue", answer: "create", recommended: true),
         CardOption(label: "Edit", answer: "edit"),
         CardOption(label: "Discard", answer: "discard", role: .destructive)]
    }

    nonisolated static func changedLine(for draft: RunnerIssueDraft) -> String? {
        guard let previous = draft.previous else { return nil }
        var fields: [String] = []
        if previous.repo != draft.fields.repo { fields.append("repository") }
        if previous.title != draft.fields.title { fields.append("title") }
        if previous.what != draft.fields.what { fields.append("What") }
        if previous.why != draft.fields.why { fields.append("Why") }
        if previous.how != draft.fields.how { fields.append("How") }
        if previous.acceptance != draft.fields.acceptance { fields.append("acceptance") }
        if previous.files != draft.fields.files { fields.append("files") }
        if previous.labels != draft.fields.labels { fields.append("labels") }
        return fields.isEmpty ? "Changed: no fields" : "Changed: " + fields.joined(separator: ", ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if draft.state == .created {
                VStack(alignment: .leading, spacing: 6) {
                    ReadingText(Self.title(for: draft), weight: .semibold)
                    if let url = draft.url { Link(draft.fields.title, destination: URL(string: url) ?? URL(fileURLWithPath: "/")) }
                }
            } else if draft.state == .discarded {
                ReadingText(Self.title(for: draft), weight: .semibold)
            } else {
                DecisionCard(title: Self.title(for: draft),
                             happened: draft.error,
                             plan: draft.preview,
                             options: Self.options(for: draft),
                             busy: draft.state == .creating,
                             keyboardEnabled: keyboardEnabled,
                             onChoose: { option in
                                 switch option.answer {
                                 case "create": onCreate()
                                 case "edit": onEdit()
                                 default: onDiscard()
                                 }
                             })
                if let changed = Self.changedLine(for: draft) {
                    ReadingText(changed, secondary: true)
                }
            }
        }
        .padding(12)
        .background(OBYStyle.surface, in: RoundedRectangle(cornerRadius: OBYStyle.card, style: .continuous))
    }
}
