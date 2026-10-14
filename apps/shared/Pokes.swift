import Foundation

/// Tapping Oby on the watch, by character/oby.html's rule: a tap within 6 seconds of the last one
/// counts up, and 6 seconds without one starts the count again. Taps 1 to 3 startle him, the 4th
/// and 5th annoy him, and from the 6th on he ignores you (each tap starts that again).
nonisolated struct Pokes {
    /// What Oby plays for a tap; the raw value names its frames (apps/watch/README.md).
    enum Reaction: String, CaseIterable {
        case poked, annoyed, ignoring
    }

    static let window: TimeInterval = 6

    /// Taps so far in this run, the latest included.
    private(set) var count = 0
    private var last: Date?

    /// Counts a tap at `time` and says what Oby plays for it.
    mutating func tap(at time: Date = .now) -> Reaction {
        if let last, time.timeIntervalSince(last) <= Self.window { count += 1 } else { count = 1 }
        last = time
        return switch count {
        case ...3: .poked
        case 4...5: .annoyed
        default: .ignoring
        }
    }
}
