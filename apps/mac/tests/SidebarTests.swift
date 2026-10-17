import Foundation
import Testing
@testable import Oby

/// The window's side panel (#11, apps/mac/app/App/Sidebar.swift) and Live's helpers
/// (apps/mac/app/App/LivePanel.swift): the counts match the header's.
/// The work's groups are WorkGroupsTests'.
struct SidebarTests {
    let now = Date(timeIntervalSince1970: 1_791_582_173)

    func job(_ id: String, status: Job.Status, created: TimeInterval = 0, agent: String = "claude") -> Job {
        var job = Job(id: id, request: "work on oby #60", agent: agent, account: "default", repo: "deskree-inc/oby",
                      branch: "oby/build-60", base: "dev", pr: nil, kind: .build, task: "Work on #60", created: now - created)
        job.status = status
        job.title = "Job \(id)"
        return job
    }

    /// Opening the window from an alert lands on the conversation, or on the job it names, from a
    /// fresh start: whatever was open before leaves.
    @MainActor @Test func openChatAlwaysReturnsToTheConversation() {
        let state = ChatState()
        #expect(state.trail.isHome)
        state.open(job: ("job", true))
        #expect(state.trail.steps == [.job(id: "job", local: true)])
        state.trail.push(.talk)
        state.open()
        #expect(state.trail.steps == [.talk])
        state.newTask()
        #expect(state.trail.isHome && state.homeFocusRequest == 1)
    }

    @Test func initialsForTheAccountPicture() {
        #expect(SidebarSections.initials("Wellington Prado") == "WP" && SidebarSections.initials("oby") == "O" && SidebarSections.initials("") == "?")
    }

    /// The conversation's icon says the last message under the pointer, and VoiceOver reads it with an unread reply.
    @Test func obysRowPreviewsTheLastMessage() {
        #expect(SidebarSections.obyPreview(nil) == "Say hello to Oby" && SidebarSections.obyPreview("Done.") == "Done.")
        #expect(SidebarSections.obyLabel(last: "Done.", unread: true) == "Oby, Done., unread reply")
        #expect(SidebarSections.obyLabel(last: nil, unread: false) == "Oby, Say hello to Oby")
    }

    /// The window's "N working", the menu bar's count and the brain's briefing all count the same
    /// jobs: this Mac's active ones and the runner's.
    @Test func theCountsAgreeWithTheHeader() {
        let here = [job("r1", status: .running, created: 300), job("q1", status: .queued, created: 100), job("f1", status: .failed)]
        let there = [job("a1", status: .running, created: 150), job("ok", status: .done)]
        // What IslandModel.working adds up: desk.active.count + feed.working.
        let header = here.count(where: \.isActive) + there.count(where: \.isActive)
        let places = [Briefing.Place(name: "this Mac", jobs: here, inbox: []), Briefing.Place(name: "tetrix-lab", jobs: there, inbox: [])]
        let briefing = Briefing(turns: [], places: places, accounts: [], now: now)
        #expect(header == 3 && briefing.working == header)
        #expect(Summary.line(working: header, needs: nil) == "3 agents are working. Nothing needs you.")
        #expect(briefing.text.contains("Working now: 3 agents are working: Job q1 on this Mac, Job a1 on tetrix-lab, Job r1 on this Mac."))
        #expect(Briefing.contradicts("No jobs are running right now.") && !Briefing.contradicts("3 agents are working."))
        #expect(!Briefing.contradicts("There are no jobs that failed today.") && !Briefing.contradicts("No jobs failed; Vault secrets is still running."))
    }

    @Test func liveProgressFollowsThePipeline() {
        var queued = job("q1", status: .queued)
        queued.phase = .prepare
        var working = job("w1", status: .running)
        working.phase = .work
        working.rounds = 4
        working.round = 3
        let queuedProgress = LiveView.progress(queued) ?? -1
        let workingProgress = LiveView.progress(working) ?? -1
        // Getting ready is at the start; round 3 of 4 is half way through Work.
        #expect(queuedProgress >= 0 && queuedProgress < 0.2)
        #expect(workingProgress > queuedProgress && workingProgress < 0.6)
        var merged = job("d1", status: .done)
        merged.phase = .work
        merged.commits = 2
        merged.published = "https://github.com/deskree-inc/oby/pull/42"
        merged.pullRequest = PullRequestStatus(state: .merged, reviewDecision: .approved, base: "dev", mergedAt: now, checkedAt: now)
        #expect((LiveView.progress(merged) ?? 0) > workingProgress)
    }
}
