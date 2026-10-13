/// Safety gates for plans produced by the keyword fallback.
nonisolated enum BrainSafety {
    /// Rules may answer questions, but they must not guess an action that changes the user's
    /// work. This is checked before Desk.card can dispatch, stop or move anything.
    static func rulesActingRefusal(for result: Planner.Result, step: Int) -> String? {
        guard step == 0, result.by == "rules" else { return nil }
        switch result.plan.action {
        case .dispatch, .stopAgent, .moveJob, .answerPermission, .setMode:
            return "Oby couldn't think that through: say it again"
        default:
            return nil
        }
    }
}
