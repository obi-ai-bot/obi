import Foundation
import Testing
@testable import Oby

/// The brain's briefing counts running jobs from the same source as the header (this Mac's desk
/// and the runner's feed), and Oby's reply never says nothing is running while the header counts
/// agents working (#11).
@MainActor
struct BriefingCountTests {
    final class FakeBrain: BrainAdapter, @unchecked Sendable {
        let name = "fake"
        var reply: String
        var prompts: [String] = []
        init(reply: String) { self.reply = reply }
        func complete(system: String, user: String, quoted: String?, schema: Data, timeout: TimeInterval) async throws -> Data {
            prompts.append(user)
            return Data(#"{"action":"reply_only","reply":"\#(reply)","question":null,"dispatches":[],"jobs":[]}"#.utf8)
        }
    }

    let folder: URL
    let desk: Desk
    let brain = FakeBrain(reply: "No jobs are running right now.")

    init() throws {
        folder = FileManager.default.temporaryDirectory.appending(path: "oby-mac-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let accounts = AccountStore(root: folder)
        accounts.setLabel("Max · well@example.com", for: "default")
        desk = Desk(accounts: accounts, store: JobStore(url: folder.appending(path: "oby.sqlite")))
        desk.repos = ["deskree-inc/oby"]
        desk.makeBrain = { [brain] _, _ in [brain] }
    }

    func job(_ id: String, title: String, created: TimeInterval) -> Job {
        var job = Job(id: id, request: "work on oby #60", agent: "claude", account: "default", repo: "deskree-inc/oby",
                      branch: "oby/build-60", base: "dev", pr: nil, kind: .build, task: "Work on #60", created: .now - created)
        job.status = .running
        job.title = title
        return job
    }

    @Test func theReplyNeverSaysNothingRunsWhileTheHeaderCountsAgents() async throws {
        // Two agents on the runner, as the feed would list them: the header says "2 agents are working."
        let there = [job("fa5a5a5a", title: "Watch home", created: 300), job("ab12cd34", title: "Vault secrets", created: 100)]
        desk.elsewhere = { [Briefing.Place(name: "tetrix-lab", jobs: there, inbox: [])] }
        let header = desk.active.count + there.count(where: \.isActive)
        #expect(Summary.line(working: header, needs: nil) == "2 agents are working. Nothing needs you.")
        #expect(desk.briefing(turns: []).working == header)
        let talk = await desk.converse("anything running?")
        #expect(talk == .reply("2 agents are working: Vault secrets on tetrix-lab, Watch home on tetrix-lab."))
        #expect(brain.prompts.last?.contains("Working now: 2 agents are working: Vault secrets on tetrix-lab, Watch home on tetrix-lab.") == true)
        #expect(desk.turns.last?.text == "2 agents are working: Vault secrets on tetrix-lab, Watch home on tetrix-lab.")
        // With nothing running, the brain's words stand.
        desk.elsewhere = { [] }
        #expect(await desk.converse("anything running?") == .reply("No jobs are running right now."))
        #expect(desk.briefing(turns: []).working == 0)
    }
}
