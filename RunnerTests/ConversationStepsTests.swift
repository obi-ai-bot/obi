import Foundation
import Testing
@testable import ObyEngine

/// Step events are the runner's live progress contract for a chat turn.
@MainActor
struct ConversationStepsTests {
    @Test func anActionSendsRunningThenDone() async {
        let desk = Desk()
        var events: [DeskStep] = []
        desk.onStepChange = { events.append($0) }
        let plan = Plan(action: .stopAgent, reply: "", dispatches: [], question: nil, all: true)

        _ = await desk.step(plan, turn: "turn-1", index: 1) { .reply("Stopped 1 job.") }

        #expect(events.map(\.turn) == ["turn-1", "turn-1"])
        #expect(events.map(\.index) == [1, 1])
        #expect(events.map { $0.action.rawValue } == ["stop_agent", "stop_agent"])
        #expect(events.map { $0.state.rawValue } == ["running", "done"])
    }

    @Test func aStoppedTurnDoesNotStartAnotherAction() async {
        let desk = Desk()
        desk.stopConversation()
        #expect(await desk.converse("stop") == .none)
    }
}
