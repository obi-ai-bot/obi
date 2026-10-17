import Foundation
import Testing
@testable import Oby

/// A task's card and page in Sangam's design (#11, apps/mac/app/App/TaskPage.swift, TaskFacts.swift):
/// how long it's been going, what it left behind, its stages' marks, its facts, what its box offers,
/// and when it shows a decision to answer in place.
struct TaskPageTests {
    let now = Date(timeIntervalSince1970: 1_791_582_173)

    func job(_ status: Job.Status, created: TimeInterval = 3600, finished: TimeInterval? = nil) -> Job {
        var job = Job(id: "j", request: "work on #412", agent: "claude", account: "deskree", repo: "deskree-inc/tetrix-ee", branch: "oby/review-412",
                      base: "dev", pr: nil, kind: .build, task: "Work", created: now - created)
        job.status = status
        job.finished = finished.map { now - $0 }
        return job
    }

    @Test func aCardSaysHowLongItsBeenGoingOrWhenItFinished() {
        #expect(TaskFacts.duration(30) == "now")
        #expect(TaskFacts.duration(18 * 60) == "18m")
        #expect(TaskFacts.duration(65 * 60) == "1h 5m")
        // An open task counts from when it started, as its page does, not from when it was queued.
        var started = job(.running, created: 3600)
        started.started = now - 5 * 60
        #expect(TaskFacts.ago(started, now: now) == "5m")
        #expect(TaskFacts.ago(job(.running, created: 18 * 60), now: now) == "18m")
        #expect(TaskFacts.ago(job(.done, created: 7200, finished: 3600), now: now) == "1h 0m ago")
        #expect(TaskFacts.ago(job(.done, created: 7200, finished: 10), now: now) == "now")
    }

    /// Done, one line: its commits, its pull request, how long it took; nothing while it runs.
    @Test func whatAFinishedTaskLeftBehind() {
        var done = job(.done, created: 40 * 60, finished: 6 * 60)
        done.started = now - 40 * 60
        done.commits = 2
        done.published = "https://github.com/deskree-inc/tetrix-ee/pull/412"
        #expect(TaskFacts.resultLine(done) == "2 commits on oby/review-412 · tetrix-ee#412 · Took 34m")
        done.commits = 1
        done.published = nil
        #expect(TaskFacts.resultLine(done) == "1 commit on oby/review-412 · Took 34m")
        #expect(TaskFacts.resultLine(job(.running)) == nil)
        #expect(TaskFacts.pullRequest("https://example.com/a/b/pull/1") == nil && TaskFacts.pullRequest("https://github.com/o/r/issues/3") == nil)
    }

    /// The stage being worked on pulses only while the agent works: orange while the task needs
    /// you, a ring once the task is done (it waits on someone else).
    /// The stage being worked on pulses only while the agent works: orange while the task needs
    /// you, a ring while it's queued or done (it waits on something else).
    @Test func eachStageGetsItsMark() {
        #expect(TaskFacts.mark(.current, needs: false, working: true) == .current)
        #expect(TaskFacts.mark(.current, needs: true, working: true) == .needs)
        #expect(TaskFacts.mark(.current, needs: false, working: false) == .upcoming)
        #expect(TaskFacts.mark(.done, needs: true, working: false) == .done)
        #expect(TaskFacts.mark(.failed, needs: false, working: false) == .failed)
        #expect(TaskFacts.mark(.skipped, needs: false, working: true) == .skipped)
    }

    /// A job waiting on Publish can be let go too; a running job can be stopped; one waiting for
    /// its time can start now.
    @Test func thePageOffersWhatTheJobCanStillDo() {
        var publish = job(.done, finished: 60)
        publish.commits = 2
        #expect(publish.canPublish, "the fixture should wait on Publish")
        #expect(TaskFacts.controls(publish).dismiss)
        var failed = job(.failed, finished: 60)
        failed.summary = "It broke."
        #expect(TaskFacts.controls(failed).dismiss)
        #expect(TaskFacts.controls(job(.running)) == TaskFacts.Controls(startNow: false, stop: true, dismiss: false))
        #expect(TaskFacts.controls(job(.done, finished: 60)) == TaskFacts.Controls())
    }

    /// A published job that runs again keeps its pull request and commits in Result.
    @Test func aPublishedJobRunningAgainKeepsItsResult() {
        var again = job(.running)
        #expect(!TaskFacts.hasResult(again))
        again.published = "https://github.com/deskree-inc/tetrix-ee/pull/412"
        #expect(TaskFacts.hasResult(again))
        again.published = nil
        again.commits = 1
        #expect(TaskFacts.hasResult(again))
    }

    @Test func detailsListTheFactsInOrder() {
        var running = job(.running)
        running.check = "swift test"
        #expect(TaskFacts.facts(running).map(\.name) == ["Repository", "Branch", "Base", "Model", "Done when"])
        #expect(TaskFacts.facts(running).first { $0.name == "Branch" }?.mono == true)
        #expect(TaskFacts.facts(running).first { $0.name == "Model" }?.value == "Account default")
    }

    /// The page's box: the agent while it runs, a follow-up once a finished one can pick its
    /// session up, nothing while it's queued or can't.
    @Test func thePagesBoxTalksToTheAgentWhenItCanListen() {
        #expect(TaskFacts.box(job(.running)) == "Tell Claude Code…")
        #expect(TaskFacts.box(job(.queued)) == nil)
        #expect(TaskFacts.box(job(.done)) == nil)
        var resumable = job(.done)
        resumable.session = "s"
        #expect(TaskFacts.box(resumable) == "Ask for a follow-up…")
    }

    /// A decision shows on the card and the page while the job waits on your OK or your answer.
    @Test func aDecisionShowsWhileTheJobWaitsOnYou() {
        var asking = job(.running)
        #expect(!TaskDecision.shows(asking, extras: nil))
        asking.question = Plan.Question(text: "Which?", options: ["A", "B"])
        #expect(TaskDecision.shows(asking, extras: nil))
        let permission = RunnerPermission(id: "p", tool: "Bash", title: "Run swift test", detail: "swift test", rule: nil, always: nil)
        #expect(TaskDecision.shows(job(.running), extras: RunnerJobExtras(id: "j", permission: permission)))
        #expect(!TaskDecision.shows(job(.done), extras: RunnerJobExtras(id: "j", permission: permission)))
    }
}
