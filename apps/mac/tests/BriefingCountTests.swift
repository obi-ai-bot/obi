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
        desk.makeBrain = { [brain] (_: String?, _: String?, _: Vault) in [brain] }
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
        // A reply about something else stands, agents or not.
        brain.reply = "There are no jobs waiting for review."
        #expect(await desk.converse("anything in review?") == .reply("There are no jobs waiting for review."))
        // With nothing running, the brain's words stand.
        brain.reply = "No jobs are running right now."
        desk.elsewhere = { [] }
        #expect(await desk.converse("anything running?") == .reply("No jobs are running right now."))
        #expect(desk.briefing(turns: []).working == 0)
    }

    /// 1 job running on the runner and 14 queued behind another's files or the update: the notch,
    /// the island's header and the brain say "1 agent is working, 14 waiting." (#238). The waiting
    /// ones say Waiting, in gray, under their own group, and the sidebar marks them queued (#496).
    @Test func theHeadlineCountsOnlyWorkingJobs() {
        let feed = RunnerFeed()
        var waiting: [Job] = []
        for index in 0..<14 {
            var queued = job("w\(index)", title: "Waiting \(index)", created: Double(index))
            queued.status = .queued
            queued.waiting = index == 0 ? Job.Waiting.update : Job.Waiting(kind: .files, text: "after #223 merges", job: "r1")
            waiting.append(queued)
            feed.apply(queued)
        }
        let running = job("r1", title: "Vault secrets", created: 300)
        feed.apply(running)
        let model = IslandModel(desk: desk, feed: feed, availability: MacAvailability())
        #expect(model.working == 1 && model.waiting == 14)
        #expect(model.summary == "1 agent is working, 14 waiting. Nothing needs you.")
        #expect(waiting.allSatisfy { $0.badge == JobBadge(text: "Waiting", tone: .gray) && $0.group == .waiting })
        #expect(waiting[1].line == "After #223 merges" && waiting[0].line == "Runner update")
        #expect(running.badge == JobBadge(text: "Working", tone: .blue) && running.group == .working)
        #expect(JobList.groups(feed.jobs, by: \.group).map(\.group) == [.working, .waiting])
        #expect(SidebarSections.work(local: [], runner: feed.jobs, since: .distantFuture, seen: []).filter { $0.mark == .queued }.count == 14)
        desk.elsewhere = { [Briefing.Place(name: "tetrix-lab", jobs: feed.jobs, inbox: [])] }
        #expect(desk.briefing(turns: []).working == model.working)
        #expect(desk.briefing(turns: []).text.contains("Working now: 1 agent is working: Vault secrets on tetrix-lab. 14 jobs are waiting."))
    }
}
