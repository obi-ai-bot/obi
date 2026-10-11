import Foundation

/// How long a job ran, as the job screen says it. Foundation only: the runner's tests build it too.
nonisolated enum Elapsed {
    /// "8m 25s", or "1h 5m" from an hour on.
    static func text(_ seconds: Int) -> String {
        let seconds = max(0, seconds)
        return seconds >= 3600 ? "\(seconds / 3600)h \(seconds % 3600 / 60)m" : "\(seconds / 60)m \(seconds % 60)s"
    }

    /// "Took 8m 25s" once the job finished, "8m 25s elapsed" while it runs.
    static func line(started: Date, finished: Date?, now: Date = .now) -> String {
        let time = text(Int((finished ?? now).timeIntervalSince(started)))
        return finished == nil ? "\(time) elapsed" : "Took \(time)"
    }

    /// How long an inbox item has waited for the user: "just now", "waiting 3m", "waiting 2h", "waiting 3d".
    static func waiting(since: Date, now: Date = .now) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(since)))
        switch seconds {
        case ..<60: return "just now"
        case ..<3600: return "waiting \(seconds / 60)m"
        case ..<86400: return "waiting \(seconds / 3600)h"
        default: return "waiting \(seconds / 86400)d"
        }
    }
}
