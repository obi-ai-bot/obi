import Foundation
#if canImport(SwiftUI)
import SwiftUI
#endif

/// The one line Home's header on the iPhone and the closed notch and the island's header on the
/// Mac all say about the jobs: who's working, and what needs you. Foundation only: the runner's
/// tests build it too.
nonisolated enum Summary {
    static let quiet = "All quiet."

    /// "2 agents are working. 1 job failed.", "1 job is ready to publish." or "All quiet."
    /// `needs` is `NeedsYou.line` over the jobs shown, without its full stop.
    static func line(working: Int, needs: String?) -> String {
        let needs = needs.map { "\($0)." }
        if working == 0 { return needs ?? quiet }
        let agents = working == 1 ? "1 agent is working." : "\(working) agents are working."
        return "\(agents) \(needs ?? "Nothing needs you.")"
    }
}

/// The groups the job list shows, in this order, on the iPhone and the Mac. The raw value is the heading.
nonisolated enum JobGroup: String, CaseIterable, Hashable, Sendable {
    case needsYou = "Needs you"
    case working = "Working"
    case inReview = "In review"
    case done = "Done"
}

/// The status pill on a job's row and screen: its words, and the colour both apps give them.
nonisolated struct JobBadge: Equatable, Sendable {
    enum Tone: Sendable { case blue, green, orange, red, gray }
    var text: String
    var tone: Tone
}

/// The job list as both apps show it: the same groups in the same order, and the same jobs hidden
/// after Clear done.
nonisolated enum JobList {
    /// One group of the list, with its jobs in the list's own order.
    nonisolated struct Section<J>: Identifiable {
        var group: JobGroup
        var jobs: [J]
        var id: JobGroup { group }
    }

    /// `jobs` in their groups, in the groups' order, each keeping the order they came in (newest
    /// first); empty groups are left out.
    static func groups<J>(_ jobs: [J], by group: (J) -> JobGroup) -> [Section<J>] {
        let grouped = Dictionary(grouping: jobs, by: group)
        return JobGroup.allCases.compactMap { group in grouped[group].map { Section(group: group, jobs: $0) } }
    }

    /// Whether a job stays in the list after Clear done: it's queued or running, it still needs
    /// the user (ready to publish, failed, interrupted, out of review rounds: only Dismiss lets
    /// those go), or `shows` keeps it by its finish time.
    static func lists(active: Bool, needsYou: Bool, finished: Date?, clearedAt: Date?) -> Bool {
        active || needsYou || shows(finished: finished, clearedAt: clearedAt)
    }

    /// Clear done by time alone: the job hasn't finished, nothing was ever cleared, or it finished
    /// after the last clear. A job that finished at the clear's second or before is hidden on
    /// every app, since the runner keeps the clear's time. `lists` is the whole rule.
    static func shows(finished: Date?, clearedAt: Date?) -> Bool {
        guard let finished, let clearedAt else { return true }
        return finished > clearedAt
    }
}

#if canImport(SwiftUI)
extension JobBadge.Tone {
    /// The same colours on the iPhone and the Mac.
    var color: Color {
        switch self {
        case .blue: .blue
        case .green: .green
        case .orange: .orange
        case .red: .red
        case .gray: .gray
        }
    }
}
#endif
