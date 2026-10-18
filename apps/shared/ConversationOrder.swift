import Foundation

/// obid's conversations as the iPhone's Conversations tab and the Mac's side panel list them (#493,
/// Sangam's Sidebar.tsx).
nonisolated enum ConversationOrder {
    /// Pinned, then the rest (Recent), each newest first.
    static func sections(_ list: [RunnerConversation]) -> (pinned: [RunnerConversation], recent: [RunnerConversation]) {
        let sorted = ordered(list)
        return (sorted.filter(\.pinned), sorted.filter { !$0.pinned })
    }

    /// A `conversation` event: in place of the one with its id, or out when it's deleted.
    static func placed(_ conversation: RunnerConversation, in list: [RunnerConversation]) -> [RunnerConversation] {
        var list = list.filter { $0.id != conversation.id }
        if !conversation.deleted { list.append(conversation) }
        return ordered(list)
    }

    /// Pinned first, then newest first.
    static func ordered(_ list: [RunnerConversation]) -> [RunnerConversation] {
        list.sorted { ($0.pinned ? 1 : 0, $0.latest) > ($1.pinned ? 1 : 0, $1.latest) }
    }

    /// Whether `conversation` is the one `said` just started: obid titles a new conversation from
    /// its first line (at most 48 characters, the first 45 and "…" when longer, its first letter
    /// upper-case), and names it in a `conversation` event as the turn begins.
    static func started(by said: String, _ conversation: RunnerConversation) -> Bool {
        guard !conversation.deleted, !conversation.title.isEmpty else { return false }
        let first = said.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n").first.map(String.init) ?? ""
        guard conversation.title.hasSuffix("…") else { return first.caseInsensitiveCompare(conversation.title) == .orderedSame }
        let cut = conversation.title.dropLast().trimmingCharacters(in: .whitespaces)
        return !cut.isEmpty && first.lowercased().hasPrefix(cut.lowercased())
    }

    /// Whether a step of Oby's turn belongs in the thread shown: a one-thread runner's always;
    /// on obid, only its own conversation's, and none while a new one waits for its id (Thinking
    /// says enough until then).
    static func shows(_ step: TurnStep, in current: String?, startingNew: Bool) -> Bool {
        shows(step.conversation, in: current, startingNew: startingNew)
    }

    /// The same for anything else of a turn under way, by its conversation (its words as they're written).
    static func shows(_ conversation: String?, in current: String?, startingNew: Bool) -> Bool {
        guard let id = conversation else { return true }
        return !startingNew && id == current
    }

    /// "now", "5m", "2h", "3d", as the design's `ago` says it.
    static func ago(_ date: Date, now: Date = .now) -> String {
        let minutes = now.timeIntervalSince(date) / 60
        if minutes < 1 { return "now" }
        if minutes < 60 { return "\(Int(minutes.rounded()))m" }
        if minutes < 24 * 60 { return "\(Int(minutes / 60))h" }
        return "\(Int(minutes / 1440))d"
    }
}
