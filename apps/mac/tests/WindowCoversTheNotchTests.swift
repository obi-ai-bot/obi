import Foundation
import Testing
@testable import Oby

/// What the notch shows that the window shows too, so #528 can take the notch away (#270): while
/// you talk, what Oby hears and how to send it; and where Clear done is.
struct WindowCoversTheNotchTests {
    @Test func listeningSaysHowToSend() {
        #expect(ListeningLine.hint(finishing: false, handsFree: false, key: "fn") == "Let go of fn to send · Oby only listens while you hold it")
        #expect(ListeningLine.hint(finishing: false, handsFree: true, key: "fn") == "Press fn to send · Oby listens until you do")
        #expect(ListeningLine.hint(finishing: true, handsFree: true, key: "Control-Option") == "Writing it down…")
    }

    @Test func completedSaysWhereClearDoneIs() {
        #expect(GroupPane.archivedLine.contains("Clear done (in Home's ⋮)"))
    }
}
