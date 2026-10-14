import Foundation
import Testing
@testable import Oby

/// Many jobs from one request, epics, balancing accounts, and stronger models for complex work (#41).
struct ManyJobsTests {
    let context = BrainContext(accounts: ["auto": ["auto"], "claude": ["auto"]], repos: ["deskree-inc/oby"])

    func state(_ id: String, agent: String = "claude", running: Int = 0, fiveHour: Double? = nil, sevenDay: Double? = nil) -> AccountState {
        AccountState(account: Account(id: id, agent: agent, name: id, payer: "", home: nil), label: "signed in",
                     fiveHour: fiveHour, sevenDay: sevenDay, running: running)
    }

    @Test func severalIssuesAreSeveralJobs() {
        let plan = Rules.plan("work on oby #12, #15 and #18 until the tests pass", context: context)
        #expect(plan.dispatches.map(\.issue) == [12, 15, 18])
        #expect(plan.dispatches.allSatisfy { $0.rounds == 5 && $0.pr == nil })
        #expect(plan.problems(in: context, canary: "7f3a9c").isEmpty)
        #expect(Rules.plan("review oby #3 and #4", context: context).dispatches.map(\.pr) == [3, 4])
    }

    @Test func anEpicIsOneComplexJobUntilObyExpandsIt() {
        let plan = Rules.plan("work on oby epic #30", context: context)
        #expect(plan.dispatches.count == 1 && plan.dispatches[0].epic == 30 && plan.dispatches[0].issue == nil)
        #expect(plan.dispatches[0].complexity == .complex)
        #expect(plan.problems(in: context, canary: "7f3a9c").isEmpty)
    }

    @Test func swiftKeepsPlansToTenGoodJobs() throws {
        var plan = Rules.plan("work on oby #12", context: context)
        plan.dispatches = Array(repeating: plan.dispatches[0], count: 11)
        #expect(plan.problems(in: context, canary: "x9").contains("dispatches holds at most 10 jobs"))
        plan.dispatches = [plan.dispatches[0]]
        plan.dispatches[0].epic = 30
        #expect(plan.problems(in: context, canary: "x9").contains("an epic job has no pr or issue: Oby finds its sub-issues"))
        plan.dispatches = []
        #expect(plan.problems(in: context, canary: "x9").contains("dispatch needs at least one job in dispatches"))
    }

    @Test func epicTaskListsNameTheirIssues() {
        let body = """
        Ship the runner.
        - [ ] #12 Linux build
        - [x] #13 already done
        * [ ] https://github.com/deskree-inc/oby/issues/14
        - [ ] write docs (no issue)
        - [ ] #12 again
        """
        #expect(Workspace.taskList(body) == [12, 14])
    }

    @Test func routingKeepsAccountsInBalance() {
        // The most weekly room left wins; a running job only breaks ties.
        let accounts = [state("busy", fiveHour: 0.6, sevenDay: 0.5), state("calm", running: 1, fiveHour: 0.2, sevenDay: 0.2),
                        state("codex", agent: "codex", sevenDay: 0.4)]
        #expect(AccountStore.route(accounts, agent: nil)?.id == "calm")
        #expect(AccountStore.route(accounts, agent: "codex")?.id == "codex")
        #expect(AccountStore.route([state("full", fiveHour: 0.96), state("ok", sevenDay: 0.79)], agent: nil)?.id == "ok")
    }

    @Test func aPlansJobsSpreadOut() {
        // What Desk.card does: route each job, counting the ones already placed.
        var states = [state("a"), state("b"), state("c", agent: "codex")]
        var placed: [String] = []
        for _ in 0..<3 {
            guard let account = AccountStore.route(states, agent: nil), let index = states.firstIndex(where: { $0.account.id == account.id }) else { break }
            states[index].running += 1
            placed.append(account.id)
        }
        #expect(Set(placed) == ["a", "b", "c"])
    }

    @Test func complexWorkIsOfferedTheStrongerModel() {
        #expect(AgentModels.stronger["claude"] == "claude-fable-5-1" && AgentModels.stronger["codex"] == "gpt-6-astra")
        #expect(AgentModels.name("claude-fable-5-1") == "Fable 5.1" && AgentModels.name("gpt-6-astra") == "GPT-6-Astra")
    }
}
