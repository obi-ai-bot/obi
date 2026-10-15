import ActivityKit
import Foundation

/// The Live Activity while agents work: compiled into the app, which starts and updates it, and
/// into the widget extension, which draws it on the Lock Screen and in the Dynamic Island.
nonisolated struct ObyActivity: ActivityAttributes {
    struct ContentState: Codable, Hashable, Sendable {
        /// Agents working now; 0 once everything has ended.
        var working: Int
        /// The newest running job, or the last one to end.
        var title: String
        /// What it's doing now, or how it ended.
        var line: String
        /// When that job started, for the clock.
        var started: Date
        /// The job's status ("running", "done", "failed"…), for the face and the color.
        var status: String
        /// "claude" or "codex".
        var agent: String
    }
}
