import Foundation
import Testing
@testable import Oby

/// The steps of Oby's turn on the Mac (#304): the runner's `step` event the feed follows, and the
/// list under the user's message (the cases are in apps/ios/tests/StepsTests.swift; apps/shared/ is one code).
@MainActor
struct MacStepsTests {
    @Test func theStepEventReachesTheThread() throws {
        var parser = EventParser()
        let wire = #"{"turn":"u1","index":1,"action":"move_job","text":"Moving Vault secrets to Codex · Deskree","state":"running","at":"2026-10-11T09:12:04Z"}"#
        for line in ["event: step", "data: \(wire)"] { #expect(parser.feed(line) == nil) }
        guard case .step(let step)? = parser.feed("") else {
            Issue.record("the step event wasn't read")
            return
        }
        let model = ConversationModel()
        model.apply(step)
        model.apply(TurnStep(turn: "u1", index: 1, action: "move_job", text: step.text, state: .done))
        model.apply(TurnStep(turn: "u1", index: 2, text: "Moving Docs to Codex", state: .running))
        #expect(model.steps["u1"]?.map(\.state) == [.done, .running] && model.working)
        // Without step events, the thread has none, as with a runner from before them.
        #expect(ConversationModel().steps.isEmpty && !ConversationModel().working)
    }
}
