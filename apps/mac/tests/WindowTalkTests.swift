import Foundation
import Testing
@testable import Oby

/// Oby as a window app (#528): what you say and where Oby answers with the window closed, and the
/// menu bar's count.
@MainActor
struct WindowTalkTests {
    @Test func listeningSaysHowToSend() {
        #expect(ListeningLine.hint(finishing: false, handsFree: false, key: "fn") == "Let go of fn to send · Oby only listens while you hold it")
        #expect(ListeningLine.hint(finishing: false, handsFree: true, key: "fn") == "Press fn to send · Oby listens until you do")
        #expect(ListeningLine.hint(finishing: true, handsFree: true, key: "Control-Option") == "Writing it down…")
    }

    @Test func completedSaysWhereClearDoneIs() {
        #expect(GroupPane.archivedLine.contains("Clear done (in Home's ⋮)"))
    }

    /// The owner's decision on #528: listening, thinking, then speaking, only while a turn started by
    /// the talk key is under way, and not over a window that shows it already.
    @Test func thePillShowsOnlyForATalkTurnTheWindowIsNotShowing() {
        #expect([TalkStage.listening, .thinking, .speaking].map(\.word) == ["Listening", "Thinking", "Speaking"])
        for stage in [TalkStage.listening, .thinking, .speaking] {
            #expect(TalkStage.shows(stage, windowShowsTalk: false))
            #expect(!TalkStage.shows(stage, windowShowsTalk: true))
        }
        #expect(!TalkStage.shows(nil, windowShowsTalk: false))
    }

    @Test func theMenuBarSaysWhatWorksAndWhatNeedsYou() {
        #expect(MenuBarLabel.label(working: 0, needsYou: 0) == "Oby")
        #expect(MenuBarLabel.label(working: 2, needsYou: 0) == "Oby: 2 working")
        #expect(MenuBarLabel.label(working: 0, needsYou: 1) == "Oby: 1 needs you")
        #expect(MenuBarLabel.label(working: 1, needsYou: 3) == "Oby: 1 working, 3 need you")
    }

    private func job(_ id: String, _ status: Job.Status) -> Job {
        var job = Job(id: id, request: "work on oby #60", agent: "claude", account: "default", repo: "deskree-inc/oby",
                      branch: "oby/build-60", base: "dev", pr: nil, kind: .build, task: "Work on #60", created: .now)
        job.status = status
        return job
    }

    /// The count beside the icon: agents working, plus what needs you, each job once however many
    /// things ask for it.
    @Test func whatNeedsYouIsCountedOncePerJob() {
        let feed = RunnerFeed()
        let model = IslandModel(desk: Desk(), feed: feed, availability: MacAvailability())
        #expect(model.working == 0 && model.needsYou == 0)
        feed.apply(job("f1", .failed))
        #expect(model.needsYou == 1)
        feed.apply(InboxItem(id: "i1", kind: .question, job: "f1", title: "Job", text: "Which?", options: ["A"], created: .now))
        #expect(model.needsYou == 1)
        feed.apply(InboxItem(id: "i2", kind: .question, job: "", title: "Oby", text: "Which?", options: ["A"], created: .now))
        #expect(model.needsYou == 2)
        feed.apply(job("r1", .running))
        #expect(model.working == 1 && model.needsYou == 2)
    }
}
