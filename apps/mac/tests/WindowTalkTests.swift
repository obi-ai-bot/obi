import AppKit
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

    /// The owner's decision on #528: the pill only while a turn started by the talk key is under way,
    /// and not over a window that shows it already. And of 2026-10-23: your words as you say them,
    /// "Thinking", then Oby's reply in writing, never "Speaking".
    @Test func thePillShowsOnlyForATalkTurnTheWindowIsNotShowing() {
        for stage in [TalkStage.listening, .thinking, .replied] {
            #expect(TalkStage.shows(stage, reply: false, windowShowsTalk: false, windowShowsConversation: false))
            #expect(!TalkStage.shows(stage, reply: false, windowShowsTalk: true, windowShowsConversation: false), "Home shows what you say")
        }
        #expect(!TalkStage.shows(nil, reply: false, windowShowsTalk: false, windowShowsConversation: false))
        #expect(TalkStage.line(.listening, words: "", problem: nil) == "Listening")
        #expect(TalkStage.line(.listening, words: "fix the vault tests", problem: nil) == "fix the vault tests")
        #expect(TalkStage.line(.listening, words: "", problem: "Oby can't use the microphone.") == "Oby can't use the microphone.")
        #expect(TalkStage.line(.thinking, words: "fix the vault tests", problem: nil) == "Thinking")
        #expect(TalkStage.line(.replied, words: "fix the vault tests", problem: nil) == nil, "the reply shows on its own")
        #expect(TalkStage.line(nil, words: "", problem: nil) == nil)
    }

    /// Home shows what you say but not Oby's reply: while a reply shows (and hands-free listens again
    /// under it), the pill shows over Home; only the conversation page keeps it away.
    @Test func theReplyShowsInThePillOverHome() {
        for stage in [TalkStage.replied, .listening] {
            #expect(TalkStage.shows(stage, reply: true, windowShowsTalk: true, windowShowsConversation: false), "Home")
            #expect(!TalkStage.shows(stage, reply: true, windowShowsTalk: true, windowShowsConversation: true), "the conversation")
            #expect(TalkStage.shows(stage, reply: true, windowShowsTalk: false, windowShowsConversation: false), "closed")
        }
    }

    /// Once Oby's reply shows, hands-free words (fn + Space) have Oby listen again at once; held-key
    /// words leave the reply showing; a key going down keeps its press; a turn under way carries on.
    @Test func handsFreeListensAgainOnceTheReplyShows() {
        #expect(TalkStage.afterReply(handsFree: true, keyDown: false, talking: false) == .listening)
        #expect(TalkStage.afterReply(handsFree: false, keyDown: false, talking: false) == .replied)
        #expect(TalkStage.afterReply(handsFree: true, keyDown: true, talking: false) == .replied, "that press is yours")
        #expect(TalkStage.afterReply(handsFree: true, keyDown: true, talking: true) == nil)
        #expect(TalkStage.afterReply(handsFree: false, keyDown: false, talking: true) == nil)
    }

    private func recording(_ key: TalkKey) -> () -> [String] {
        var events: [String] = []
        key.on = { event in
            switch event {
            case .press: events.append("press")
            case .start: events.append("start")
            case .handsFree: events.append("handsFree")
            case .send: events.append("send")
            case .cancel: events.append("cancel")
            }
        }
        return { events }
    }

    private func fn(_ key: TalkKey, down: Bool) {
        _ = key.handle(.flagsChanged, code: 63, flags: down ? .maskSecondaryFn : [], repeating: false)
    }

    /// The reply lands while fn is going down, in the moment before its turn starts: Oby doesn't take
    /// that press over for hands-free. fn's own turn starts, and letting go sends it, so the
    /// microphone closes with the key.
    @Test func aReplyDuringAPressLeavesThePressToYou() async throws {
        let key = TalkKey()
        let events = recording(key)
        fn(key, down: true)
        #expect(key.busy && !key.listenAgain(), "the press is yours")
        for _ in 0..<40 where !events().contains("start") { try await Task.sleep(for: .milliseconds(50)) }
        fn(key, down: false)
        #expect(events() == ["press", "start", "send"])
        #expect(!key.busy, "nothing listens after the key is let go")
    }

    /// With no key down, Oby listens again after its reply, and the next press ends it.
    @Test func listeningAgainEndsAtTheNextPress() {
        let key = TalkKey()
        let events = recording(key)
        #expect(!key.busy && key.listenAgain())
        #expect(key.busy && !key.listenAgain(), "once")
        fn(key, down: true)
        fn(key, down: false)
        #expect(events() == ["press", "send"])
        #expect(!key.busy)
    }

    /// A regular Mac app (#528): a Dock icon, and its own menus while its window is in front, with
    /// Edit (the composer's Undo, Cut, Copy, Paste) and Window (Minimize, Zoom, Oby's window).
    @Test func obyIsARegularAppWithItsOwnMenus() {
        #expect(NSApp.activationPolicy() == .regular)
        let menus = NSApp.mainMenu?.items.map(\.title) ?? []
        #expect(menus.contains("Edit") && menus.contains("Window"), "\(menus)")
        let edit = NSApp.mainMenu?.items.first { $0.title == "Edit" }?.submenu?.items.map(\.title) ?? []
        for item in ["Undo", "Redo", "Cut", "Copy", "Paste", "Select All"] { #expect(edit.contains(item), "\(item) in \(edit)") }
    }

    /// The Dock icon clicked with the window closed opens it; with it up, macOS brings it forward.
    /// Closing the window never quits Oby: the talk key, its pill and the menu bar icon carry on.
    @Test func theDockIconOpensTheWindowAndClosingItKeepsObyRunning() {
        let app = AppDelegate()
        var opened = 0
        app.reopen = { opened += 1 }
        #expect(app.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false) && opened == 1)
        #expect(app.applicationShouldHandleReopen(NSApp, hasVisibleWindows: true) && opened == 1)
        #expect(!app.applicationShouldTerminateAfterLastWindowClosed(NSApp))
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
