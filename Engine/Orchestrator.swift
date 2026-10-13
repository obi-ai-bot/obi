import Foundation

/// A compact, Oby-authored notification. Evidence is addressed by job id and read from the
/// runner's stores only after the brain asks for it.
nonisolated struct OrchestratorEvent: Sendable, Equatable {
    var kind: String
    var job: String
    var item: String? = nil
    var summary: String
    var evidence: [String] = []
}

nonisolated enum OrchestratorInbox {
    static func escalation(events: [OrchestratorEvent], why: String) -> InboxItem {
        let event = events.first
        let id = "orchestrator-\(UUID().uuidString.lowercased())"
        let title = event.map { $0.job.isEmpty ? "Job event needs your decision" : "Job \($0.job) needs your decision" } ?? "Job event needs your decision"
        let summary = events.map(\.summary).joined(separator: " ")
        let review = events.contains { $0.kind == "review_error" }
        return InboxItem(id: id, kind: review ? .review : .question, job: event?.job ?? "", title: title,
                         text: "\(why) \(summary)",
                         options: review ? [Inbox.retryReview, Inbox.oneMoreRound, Inbox.dismiss] : [], created: .now)
    }
}
