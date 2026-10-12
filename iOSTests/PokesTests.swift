import Foundation
import Testing
@testable import Oby

/// Tapping Oby on the watch counts as oby.html counts clicks.
struct PokesTests {
    private let start = Date(timeIntervalSinceReferenceDate: 0)

    /// Taps 1 to 3 startle him, 4 and 5 annoy him, and from the 6th on he ignores you.
    @Test func tapsCloseTogetherCountUp() {
        var pokes = Pokes()
        let reactions = (0..<8).map { pokes.tap(at: start.addingTimeInterval(Double($0) * 5)) }
        #expect(reactions == [.poked, .poked, .poked, .annoyed, .annoyed, .ignoring, .ignoring, .ignoring])
        #expect(pokes.count == 8)
    }

    /// Six seconds still counts; longer without a tap starts again from the first.
    @Test func sixSecondsWithoutATapStartsAgain() {
        var pokes = Pokes()
        for second in [0.0, 1, 2, 3] { _ = pokes.tap(at: start.addingTimeInterval(second)) }
        #expect(pokes.tap(at: start.addingTimeInterval(9)) == .annoyed)
        #expect(pokes.tap(at: start.addingTimeInterval(15.1)) == .poked)
        #expect(pokes.count == 1)
    }
}
