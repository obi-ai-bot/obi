import Foundation

/// One action in a conversation turn, sent to the runner's event stream.
nonisolated struct DeskStep: Encodable, Sendable {
    var turn: String
    var index: Int
    var action: Plan.Action
    var text: String
    var state: State
    var at: Date = .now

    enum State: String, Encodable, Sendable { case running, done, failed }
}

extension Desk {
    /// Runs one brain action and reports its boundaries without changing the action itself.
    func step(_ plan: Plan, turn: String, index: Int, _ work: () async -> Talk) async -> Talk {
        guard Self.acting.contains(plan.action) else { return await work() }
        let text = stepText(plan)
        onStepChange(DeskStep(turn: turn, index: index, action: plan.action, text: text, state: .running))
        let result = await work()
        let failed: Bool
        if case .reply(let reply) = result { failed = reply.hasPrefix("Couldn't") || reply.hasPrefix("Say which") }
        else { failed = false }
        onStepChange(DeskStep(turn: turn, index: index, action: plan.action, text: text,
                              state: failed ? .failed : .done))
        return result
    }

    private func stepText(_ plan: Plan) -> String {
        switch plan.action {
        case .moveJob:
            let names = (plan.jobs ?? []).compactMap { job($0)?.heading }
            let destination = plan.move.map { move in
                let tool = Job.agentNames[move.agent]
                return [tool, move.account == "auto" ? nil : move.account].compactMap { $0 }.joined(separator: " · ")
            }.flatMap { $0.isEmpty ? nil : $0 } ?? "the selected destination"
            return "Moving \(names.isEmpty ? "jobs" : names.joined(separator: ", ")) to \(destination ?? "the selected destination")"
        case .stopAgent: return plan.all == true ? "Stopping all running work" : "Stopping the selected work"
        case .answerPermission: return "Answering a permission request"
        case .setMode: return "Changing permission mode"
        case .dispatch, .askUser, .replyOnly, .ignore, .readJob, .setSetting, .fixFailure: return plan.action.rawValue
        case .research: return "Looking up context"
        case .retryJob, .dismissJob, .startNow, .messageJob, .askReviewAgain:
            let names = (plan.jobs ?? []).compactMap { job($0)?.heading }
            let what = names.isEmpty ? "the selected jobs" : names.joined(separator: ", ")
            switch plan.action {
            case .retryJob: return "Trying \(what) again"
            case .dismissJob: return "Letting \(what) go"
            case .askReviewAgain: return "Asking for another review of \(what)"
            default: return "Starting \(what) now"
            }
        case .answerInbox: return "Answering an inbox item"
        }
    }
}
