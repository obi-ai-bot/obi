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
            #expect(TalkStage.shows(stage, reply: false, windowShowsTalk: false, windowShowsReply: false))
            #expect(!TalkStage.shows(stage, reply: false, windowShowsTalk: true, windowShowsReply: false), "Home shows what you say")
        }
        #expect(!TalkStage.shows(nil, reply: false, windowShowsTalk: false, windowShowsReply: false))
        #expect(TalkStage.line(.listening, words: "", problem: nil) == "Listening")
        #expect(TalkStage.line(.listening, words: "fix the vault tests", problem: nil) == "fix the vault tests")
        #expect(TalkStage.line(.listening, words: "", problem: "Oby can't use the microphone.") == "Oby can't use the microphone.")
        #expect(TalkStage.line(.thinking, words: "fix the vault tests", problem: nil) == "Thinking")
        #expect(TalkStage.line(.replied, words: "fix the vault tests", problem: nil) == nil, "the reply shows on its own")
        #expect(TalkStage.line(nil, words: "", problem: nil) == nil)
    }

    /// Home shows what you say but not Oby's reply: while a reply shows (and hands-free listens again
    /// under it), the pill shows unless the window shows the conversation the words went to.
    @Test func theReplyShowsInThePillUnlessItsConversationShows() {
        for stage in [TalkStage.replied, .listening] {
            #expect(TalkStage.shows(stage, reply: true, windowShowsTalk: true, windowShowsReply: false), "Home, or another conversation")
            #expect(!TalkStage.shows(stage, reply: true, windowShowsTalk: true, windowShowsReply: true), "its conversation")
            #expect(TalkStage.shows(stage, reply: true, windowShowsTalk: false, windowShowsReply: false), "closed")
        }
    }

    /// Only words asked hands-free (fn + Space) have their reply listen again, once: not held-key
    /// words, even after an fn + Space with nothing said while they wait (the mic rule), nor after
    /// a bare "never mind".
    @Test func onlyWordsAskedHandsFreeListenAgain() {
        var turn = TalkTurn()
        _ = turn.heard("fix the vault tests", handsFree: true, again: false, problem: false)
        let r1 = turn.replied("On it.", keyDown: false, talking: false)
        #expect(r1 == .listenAgain)
        let r2 = turn.replied("And done.", keyDown: false, talking: false)
        #expect(r2 == .show(announce: true), "once")

        // Held fn, then fn + Space while they wait, nothing said, pressed again: the reply only shows.
        turn = TalkTurn()
        _ = turn.heard("fix the vault tests", handsFree: false, again: false, problem: false)
        let r3 = turn.closed()
        #expect(!r3)
        let r4 = turn.heard("", handsFree: true, again: false, problem: false)
        #expect(r4, "Oby didn't catch that")
        let r5 = turn.replied("On it.", keyDown: false, talking: false)
        #expect(r5 == .show(announce: true))

        // Hands-free words, then nothing heard or a bare "never mind": hands-free is over.
        for ending in ["", "never mind"] {
            turn = TalkTurn()
            _ = turn.heard("fix the vault tests", handsFree: true, again: false, problem: false)
            _ = turn.heard(ending, handsFree: true, again: false, problem: false)
            let r6 = turn.replied("On it.", keyDown: false, talking: false)
            #expect(r6 == .show(announce: true), "\(ending)")
        }

    }

    /// Hands-free lasts until the next press (AGENTS.md): a press while Oby thinks (a short fn tap,
    /// Control-Option, Stop all), or while the words are still being written down, ends it, so the
    /// reply only shows.
    @Test func aPressAfterHandsFreeWordsEndsHandsFree() {
        var turn = TalkTurn()
        _ = turn.pressed()
        _ = turn.closed()
        _ = turn.heard("fix the vault tests", handsFree: true, again: false, problem: false)
        _ = turn.pressed()
        let thinking = turn.replied("On it.", keyDown: false, talking: false)
        #expect(thinking == .show(announce: true), "a press while Oby thinks")

        turn = TalkTurn()
        _ = turn.pressed()
        _ = turn.closed()
        _ = turn.pressed()
        _ = turn.heard("fix the vault tests", handsFree: true, again: false, problem: false)
        let writing = turn.replied("On it.", keyDown: false, talking: false)
        #expect(writing == .show(announce: true), "a tap while the words are written down")

        // The press that sends hands-free words comes before their send: it doesn't count against them.
        turn = TalkTurn()
        _ = turn.pressed()
        _ = turn.closed()
        _ = turn.heard("fix the vault tests", handsFree: true, again: false, problem: false)
        let asked = turn.replied("On it.", keyDown: false, talking: false)
        #expect(asked == .listenAgain)
    }

    /// The reply lands while a key is going down, or while you're talking already: that press and
    /// that turn are yours. Nothing listens again by itself, and VoiceOver stays quiet.
    @Test func aReplyNeverTakesOverYourPress() {
        var turn = TalkTurn()
        _ = turn.heard("fix the vault tests", handsFree: true, again: false, problem: false)
        let r8 = turn.replied("On it.", keyDown: true, talking: false)
        #expect(r8 == .show(announce: false))
        let r9 = turn.pressed()
        #expect(!r9, "nothing to cut off")
        _ = turn.heard("fix the vault tests", handsFree: true, again: false, problem: false)
        let r10 = turn.replied("On it.", keyDown: true, talking: true)
        #expect(r10 == .carryOn)
    }

    /// A blank reply ends the turn: no empty pill, nothing listens again.
    @Test func aBlankReplyEndsTheTurn() {
        var turn = TalkTurn()
        _ = turn.heard("fix the vault tests", handsFree: true, again: false, problem: false)
        let r11 = turn.replied(" \n", keyDown: false, talking: false)
        #expect(r11 == .end)
        #expect(!turn.relistening && !turn.announced)
        let r12 = turn.replied("Late words.", keyDown: false, talking: false)
        #expect(r12 == .show(announce: true), "its hands-free went with it")
    }

    /// VoiceOver reads the reply, and the next press cuts it off, whenever it comes.
    @Test func theNextPressCutsVoiceOverOff() {
        var turn = TalkTurn()
        _ = turn.heard("how are the vault tests", handsFree: false, again: false, problem: false)
        let r13 = turn.replied("They pass.", keyDown: false, talking: false)
        #expect(r13 == .show(announce: true))
        let r14 = turn.pressed()
        #expect(r14)
        let r15 = turn.pressed()
        #expect(!r15, "once")
    }

    /// Oby listening again by itself, ended by a press with nothing said: quietly, unless something
    /// went wrong. Your own press with nothing said still says Oby didn't catch it.
    @Test func endingListeningAgainSaysNothing() {
        var turn = TalkTurn()
        _ = turn.heard("fix the vault tests", handsFree: true, again: false, problem: false)
        let r16 = turn.replied("Which repository?", keyDown: false, talking: false)
        #expect(r16 == .listenAgain)
        let again = turn.closed()
        #expect(again && !turn.relistening)
        let r17 = turn.heard("", handsFree: true, again: again, problem: false)
        #expect(!r17)
        let r18 = turn.heard("", handsFree: true, again: again, problem: true)
        #expect(r18, "the microphone failed")
        let r19 = turn.heard("", handsFree: false, again: false, problem: false)
        #expect(r19, "your own press")
        // A turn of yours started meanwhile: its empty words aren't Oby's listening.
        _ = turn.heard("fix it", handsFree: true, again: false, problem: false)
        _ = turn.replied("Which one?", keyDown: false, talking: false)
        turn.started()
        let r20 = turn.closed()
        #expect(!r20)
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
