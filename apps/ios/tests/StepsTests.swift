import Foundation
import Testing
@testable import Oby

/// The steps of Oby's turn (#304): the runner's `step` event, read as optional (older runners send
/// none), and the list the chats show under the user's message, in order, with each step's state.
@MainActor
struct StepsTests {
    func step(_ index: Int, _ state: TurnStep.State, turn: String = "u1", text: String? = nil) -> TurnStep {
        TurnStep(turn: turn, index: index, action: "move_job", text: text ?? "Step \(index)", state: state)
    }

    func event(_ json: String) -> RunnerEvent? {
        var parser = EventParser()
        for line in ["event: step", "data: \(json)"] { #expect(parser.feed(line) == nil) }
        return parser.feed("")
    }

    // MARK: Decoding

    @Test func theStepEventIsRead() throws {
        let wire = #"{"turn":"7c1e2f30","index":1,"action":"move_job","text":"Moving Vault secrets to Codex · Deskree","state":"running","at":"2026-10-11T09:12:04Z"}"#
        let read = try Runner.decoder.decode(TurnStep.self, from: Data(wire.utf8))
        #expect(read.turn == "7c1e2f30" && read.index == 1 && read.action == "move_job" && read.state == .running)
        #expect(read.text == "Moving Vault secrets to Codex · Deskree" && read.id == "7c1e2f30#1")
        #expect(read.at == ISO8601DateFormatter().date(from: "2026-10-11T09:12:04Z"))
        #expect(event(wire) == .step(read))
        for (name, state) in [("done", TurnStep.State.done), ("failed", .failed)] {
            let ended = try Runner.decoder.decode(TurnStep.self, from: Data(wire.replacingOccurrences(of: "running", with: name).utf8))
            #expect(ended.state == state)
        }
    }

    /// A runner from before steps never sends the event, and a newer one may leave out or add to its keys.
    @Test func theStepEventMayBeMissingOrThin() throws {
        // Missing: the other events read as before, and a stream with no step ends with no steps.
        var parser = EventParser()
        for line in ["event: turn", #"data: {"id":"a","who":"user","text":"hi","at":"2026-10-11T09:12:04Z","jobs":[]}"#] { _ = parser.feed(line) }
        guard case .turn(let turn, _)? = parser.feed("") else {
            Issue.record("the turn event wasn't read")
            return
        }
        let model = ConversationModel()
        model.apply(turn)
        #expect(model.steps.isEmpty && !model.working && model.steps(under: turn, in: [turn]).isEmpty)
        // Thin: no action and no time still shows the step; a state this app doesn't know reads as done.
        let thin = try Runner.decoder.decode(TurnStep.self, from: Data(#"{"turn":"a","index":2,"text":"Checking","state":"paused"}"#.utf8))
        #expect(thin.action == nil && thin.at == nil && thin.state == .done && thin.text == "Checking")
        let badTime = try Runner.decoder.decode(TurnStep.self, from: Data(#"{"turn":"a","index":2,"text":"Checking","state":"done","at":"yesterday"}"#.utf8))
        #expect(badTime.at == nil && badTime.state == .done)
        // Without what identifies the step it isn't one, and the event is dropped.
        #expect(event(#"{"index":1,"text":"x","state":"done"}"#) == nil)
    }

    @Test func theStepSurvivesTheWatchRelay() throws {
        let sent = TurnStep(turn: "u1", index: 3, action: "move_job", text: "Moving", state: .failed, at: Date(timeIntervalSince1970: 1_791_582_173))
        let back = try Runner.decoder.decode(TurnStep.self, from: try Runner.encoder.encode(sent))
        #expect(back == sent)
    }

    // MARK: The list

    @Test func stepsStayInOrderAndChangeState() {
        let model = ConversationModel()
        // Events come in order; each step comes again as it ends, and a late one finds its place.
        model.apply(step(1, .running))
        #expect(model.working && model.steps["u1"]?.map(\.state) == [.running])
        model.apply(step(1, .done))
        model.apply(step(2, .running))
        model.apply(step(3, .running))
        model.apply(step(2, .failed))
        #expect(model.steps["u1"]?.map(\.index) == [1, 2, 3])
        #expect(model.steps["u1"]?.map(\.state) == [.done, .failed, .running])
        #expect(model.working)
        model.apply(step(3, .done))
        #expect(model.steps["u1"]?.map(\.state) == [.done, .failed, .done] && !model.working)
        #expect(ConversationModel.placed(step(2, .done), in: [step(1, .done), step(3, .done)]).map(\.index) == [1, 2, 3])
        // Another turn's steps stay apart.
        model.apply(step(1, .running, turn: "u2"))
        #expect(model.steps["u2"]?.count == 1 && model.steps["u1"]?.count == 3 && model.working)
    }

    @Test func theStepsShowUnderTheUsersTurn() {
        let said = Turn(id: "u1", date: .now, who: .user, text: "Move the failed jobs to Codex")
        let answer = Turn(id: "o1", date: .now.addingTimeInterval(5), who: .oby, text: "Moved 2 jobs.")
        let model = ConversationModel()
        model.apply(step(1, .done))
        model.apply(step(2, .running))
        let thread = [said, answer]
        #expect(model.steps(under: said, in: thread).map(\.index) == [1, 2])
        #expect(model.steps(under: answer, in: thread).isEmpty)
        // The phone's echo of the words has its own id until the runner lists them: the last user
        // turn takes the steps of a turn the thread doesn't have yet.
        let echo = Turn(id: "echo", date: .now, who: .user, text: "Move the failed jobs to Codex")
        #expect(model.steps(under: echo, in: [echo]).map(\.index) == [1, 2])
        let earlier = Turn(id: "u0", date: .now.addingTimeInterval(-60), who: .user, text: "Hi")
        #expect(model.steps(under: earlier, in: [earlier, echo]).isEmpty)
    }

    @Test func stopAndTheAnswerEndWhatRuns() async {
        let model = ConversationModel()
        model.apply(step(1, .done))
        model.apply(step(2, .running))
        // Stop: what ran failed; what was done stays.
        model.settleSteps()
        #expect(model.steps["u1"]?.map(\.state) == [.done, .failed] && !model.working)
        // The answer came without the end of a step: done.
        model.apply(step(3, .running))
        model.settleLatestSteps()
        #expect(model.steps["u1"]?.map(\.state) == [.done, .failed, .done])
        // A reload, after a dropped connection, keeps no spinner turning for ever.
        model.apply(step(4, .running))
        await model.reload()
        #expect(!model.working && model.steps["u1"]?.last?.state == .failed)
        model.forget()
        #expect(model.steps.isEmpty && model.latestStepTurn == nil)
    }

    @Test func aPlanWaitsUpToTwoMinutes() {
        #expect(Runner.planTimeout == 120)
    }
}
