import Foundation
import Testing
@testable import ObyEngine

/// The live step events and stop-after-an-action behavior of a conversation turn.
@MainActor
struct ConversationStepsTests {
    final class ScriptedBrain: BrainAdapter, @unchecked Sendable {
        let name = "scripted"
        var plans: [String]
        var answered: [String] = []

        init(_ plans: [String]) { self.plans = plans }

        func complete(system: String, user: String, quoted: String?, schema: Data, timeout: TimeInterval) async throws -> Data {
            let plan = plans.removeFirst()
            answered.append(plan)
            return Data(plan.utf8)
        }
    }

    final class IdleAgent: AgentRun {
        func start(prompt: String, onEvent: @escaping (AgentEvent) -> Void) throws {}
        func send(_ text: String) {}
        func end() {}
        func stop() {}
        func kill() {}
    }

    @Test func aTwoStepTurnSendsEachRunningAndDoneEventInOrder() async throws {
        let (desk, _) = try makeDesk(plans: [setMode("ask"), setMode("acceptEdits"), reply("Done.")])
        desk.enqueue(job())
        try await waitUntil { desk.jobs.first?.isActive == true }

        var events: [DeskStep] = []
        desk.onStepChange = { events.append($0) }

        #expect(await desk.converse("change the mode twice") == .reply("Vault secrets is in Ask mode now. Vault secrets is in Accept edits mode now. Done."))
        #expect(events.map { "\($0.index):\($0.action.rawValue):\($0.state.rawValue)" } == [
            "1:set_mode:running", "1:set_mode:done", "2:set_mode:running", "2:set_mode:done",
        ])
    }

    @Test func stoppingAfterTheFirstStepDoesNotStartAnotherAction() async throws {
        let (desk, brain) = try makeDesk(plans: [setMode("ask"), setMode("acceptEdits")])
        desk.enqueue(job())
        try await waitUntil { desk.jobs.first?.isActive == true }

        var events: [DeskStep] = []
        desk.onStepChange = { event in
            events.append(event)
            if event.index == 1, event.state == .done { desk.stopConversation() }
        }

        #expect(await desk.converse("change the mode, then change it again") == .reply("Vault secrets is in Ask mode now."))
        #expect(events.map { "\($0.index):\($0.state.rawValue)" } == ["1:running", "1:done"])
        #expect(brain.answered.count == 1)
    }

    private func makeDesk(plans: [String]) throws -> (Desk, ScriptedBrain) {
        let folder = try temporaryFolder()
        let accounts = AccountStore(root: folder)
        accounts.setLabel("Max · well@example.com", for: "default")
        let desk = Desk(accounts: accounts, store: JobStore(url: folder.appending(path: "oby.sqlite")))
        desk.repos = ["deskree-inc/oby"]
        desk.prepare = { $0 }
        desk.makeAgent = { _, _, _ in IdleAgent() }
        let brain = ScriptedBrain(plans)
        desk.makeBrain = { [brain] (_: String?, _: String?, _: Vault) in [brain] }
        return (desk, brain)
    }

    private func job() -> Job {
        var job = Job(id: "ab12cd34", request: "work on oby #60", agent: "claude", account: "default",
                      repo: "deskree-inc/oby", branch: "oby/build-60", base: "dev", pr: nil,
                      kind: .build, task: "Work on #60")
        job.issue = 60
        job.title = "Vault secrets"
        return job
    }

    private func waitUntil(_ condition: @escaping () -> Bool) async throws {
        for _ in 0..<500 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
        #expect(condition())
    }

    private func setMode(_ mode: String) -> String {
        #"{"action":"set_mode","reply":"","question":null,"dispatches":[],"jobs":["ab12cd34"],"mode":"\#(mode)"}"#
    }

    private func reply(_ text: String) -> String {
        #"{"action":"reply_only","reply":"\#(text)","question":null,"dispatches":[],"jobs":[]}"#
    }
}
