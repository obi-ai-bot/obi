import Foundation
import Testing
@testable import ObyEngine

struct BrainSteadyTests {
    final class ModelFake: ModelAwareBrainAdapter, @unchecked Sendable {
        let name = "fake"
        var models: [String] = []
        var failNext = false
        func complete(system: String, user: String, quoted: String?, schema: Data, timeout: TimeInterval) async throws -> Data {
            try await complete(model: ClaudeBrain.quickModel, system: system, user: user, quoted: quoted, schema: schema, timeout: timeout)
        }
        func complete(model: String, system: String, user: String, quoted: String?, schema: Data, timeout: TimeInterval) async throws -> Data {
            models.append(model)
            if failNext {
                failNext = false
                throw Shell.Failure(message: "transient")
            }
            return Data(#"{"action":"reply_only","reply":"Ready","dispatches":[],"question":null}"#.utf8)
        }
    }

    let context = BrainContext(accounts: ["claude": ["default"]], repos: ["deskree-inc/oby"])

    @Test func aLongRequestUsesSonnet() async {
        let fake = ModelFake()
        var long = context
        long.turnLength = 1_500
        _ = await Planner(adapters: [fake]).plan(String(repeating: "x", count: 1_500), context: long)
        #expect(fake.models == [ClaudeBrain.deepModel])
    }

    @Test func aTransientModelFailureRetriesAndUsesTheModelAnswer() async {
        let fake = ModelFake()
        fake.failNext = true
        let result = await Planner(adapters: [fake]).plan("hello", context: context)
        #expect(result.by == "fake")
        #expect(result.plan.reply == "Ready")
        #expect(fake.models == [ClaudeBrain.quickModel, ClaudeBrain.quickModel])
    }

    @Test func laterStepsUseSonnetAndQuickQuestionsUseHaiku() async {
        let fake = ModelFake()
        var next = context
        next.turnStep = 1
        _ = await Planner(adapters: [fake]).plan("continue", context: next)
        next.turnStep = 0
        next.turnLength = 20
        _ = await Planner(adapters: [fake]).plan("what now?", context: next)
        #expect(fake.models == [ClaudeBrain.deepModel, ClaudeBrain.quickModel])
    }

    @Test func rulesCannotActOnTheFirstStep() {
        let plan = Plan(action: .dispatch, reply: "", dispatches: [], question: nil)
        let result = Planner.Result(plan: plan, by: "rules")
        #expect(BrainSafety.rulesActingRefusal(for: result, step: 0) == "Oby couldn't think that through: say it again")
        #expect(BrainSafety.rulesActingRefusal(for: result, step: 1) == nil)
        let question = Planner.Result(plan: Plan(action: .askUser, reply: "", dispatches: [], question: Plan.Question(text: "Which repository?", options: [])), by: "rules")
        #expect(BrainSafety.rulesActingRefusal(for: question, step: 0) == nil)
    }
}
