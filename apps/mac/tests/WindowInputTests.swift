import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Oby

/// The window's input (#270): clicks in the title bar's band and Esc, on the real window
/// (ChatWindow.make), kept off screen. Serialized: the key window is the app's, one at a time.
@MainActor
@Suite(.serialized)
struct WindowInputTests {
    let now = Date.now

    func model() -> IslandModel {
        let feed = RunnerFeed()
        var job = Job(id: "r1", request: "review", agent: "claude", account: "deskree", repo: "deskree-inc/oby", branch: "b", base: "dev",
                      pr: nil, kind: .review, task: "review", created: now - 60)
        job.status = .running
        feed.apply(job)
        return IslandModel(desk: Desk(), feed: feed, availability: MacAvailability())
    }

    /// The panel's settings live in the app's own defaults (the test host is the app): set for a
    /// test, then put back as they were.
    func withPanel(open: Bool, _ work: () async throws -> Void) async throws {
        let defaults = UserDefaults.standard, keys = ["ObySidebarOpen", "ObySidebarWidth"]
        let before = keys.map { defaults.object(forKey: $0) }
        defer { for (key, value) in zip(keys, before) { if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) } } }
        defaults.set(open, forKey: "ObySidebarOpen")
        defaults.set(Double(Tokens.sidebar), forKey: "ObySidebarWidth")
        try await work()
    }

    /// The title bar shares its band with the toolbar: a click there must still reach the window's
    /// own buttons (the panel's toggle, back to Home), not only drag the window.
    @Test func clicksInTheTitleBarReachItsButtons() async throws {
        try await withPanel(open: false) {
            let state = ChatState(defaults: .scratch)
            state.trail.start(.group(.review))
            let window = ChatWindow.make(ChatView(model: model(), state: state, character: nil))
            window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
            window.orderFrontRegardless()
            window.makeKey()
            defer { window.close() }
            ChatWindow.measureLights(window, into: state)
            try await Task.sleep(for: .milliseconds(600))
            let height = window.contentView?.bounds.height ?? 0
            func click(_ x: CGFloat) async throws {
                let at = NSPoint(x: x, y: height - state.chrome.bar / 2)
                for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    let event = try #require(NSEvent.mouseEvent(with: type, location: at, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
                    window.sendEvent(event)
                }
                try await Task.sleep(for: .milliseconds(400))
            }
            // Back, right of the panel's toggle while the panel is closed.
            try await click(state.chrome.afterLights + 40 + 16)
            #expect(state.trail.isHome, "the back chevron didn't get the click")
            try await click(state.chrome.afterLights + 16)
            #expect(UserDefaults.standard.bool(forKey: "ObySidebarOpen"), "the panel's toggle didn't get the click")
        }
    }

    /// Esc goes back a page, even from where the keyboard was: typing in Home's box and then
    /// opening a kind of work's page (the box hides, and must let go), and in the conversation
    /// while its box has the keyboard (with nothing to stop).
    @Test func escapeGoesBackAPage() async throws {
        try await withPanel(open: true) {
            for start in [WindowStep.group(.review), .talk] {
                let state = ChatState(defaults: .scratch)
                if start == .talk { state.open() } else { state.newTask() }
                let window = ChatWindow.make(ChatView(model: model(), state: state, character: nil))
                window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
                window.orderFrontRegardless()
                window.makeKey()
                defer { window.close() }
                for _ in 0..<60 where !(window.firstResponder is ComposerEditor.Editor) { try await Task.sleep(for: .milliseconds(50)) }
                #expect(window.firstResponder is ComposerEditor.Editor, "the box never took the keyboard")
                if start != .talk {
                    state.trail.start(start)
                    try await Task.sleep(for: .milliseconds(600))
                }
                let escape = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                           windowNumber: window.windowNumber, context: nil, characters: "\u{1b}",
                                                           charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
                window.sendEvent(escape)
                try await Task.sleep(for: .milliseconds(400))
                #expect(state.trail.isHome, "Esc didn't go back from \(start); first responder: \(String(describing: window.firstResponder))")
            }
        }
    }

    /// The tasks page as Sangam's GroupView (#822): a click on a card stays on the page, and one on
    /// the page's empty space goes back.
    @Test func theTasksPageClosesOnAClickOnNothing() async throws {
        try await withPanel(open: false) {
            let model = model()
            model.feed.apply(GitHubWork.busy(now: now))
            let state = ChatState(defaults: .scratch)
            state.trail.start(.group(.issues))
            let window = ChatWindow.make(ChatView(model: model, state: state, character: nil))
            window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
            window.orderFrontRegardless()
            window.makeKey()
            defer { window.close() }
            ChatWindow.measureLights(window, into: state)
            try await Task.sleep(for: .milliseconds(800))
            let size = try #require(window.contentView?.bounds.size)
            func click(_ at: NSPoint) async throws {
                for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    let event = try #require(NSEvent.mouseEvent(with: type, location: at, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
                    window.sendEvent(event)
                    try await Task.sleep(for: .milliseconds(80))
                }
                try await Task.sleep(for: .milliseconds(400))
            }
            // The first card's Later, under the filters row: the clicks reach the page's buttons.
            try await click(NSPoint(x: size.width / 2 - 21, y: size.height - 407))
            #expect(model.feed.gitHubLater.contains("is0"), "Later didn't get the click")
            // The first card's right half, between its column chip and its headline: still on the page.
            try await click(NSPoint(x: size.width / 2 + 160, y: size.height - 334))
            #expect(state.trail.top == .group(.issues), "a click on a card closed the page")
            // Left of the column, halfway down: nothing there, so back Home.
            try await click(NSPoint(x: 40, y: size.height / 2))
            #expect(state.trail.isHome, "a click on the page's empty space didn't go back: \(String(describing: state.trail.top)) size \(size)")
        }
    }

    /// Under Completed, "Older ones are in Archived" spans its row (Sangam's `.group-archived`): a
    /// click well left of the words opens Archived, not back Home.
    @Test func archivedOpensFromBesideItsWords() async throws {
        try await withPanel(open: false) {
            let model = model()
            for (id, ago) in [("t1", 6000.0), ("t2", 30000.0)] {
                var job = Job(id: id, request: "task \(id)", agent: "claude", account: "deskree", repo: "deskree-inc/oby", branch: "b", base: "dev",
                              pr: nil, kind: .build, task: "task \(id)", created: now - ago)
                job.status = .done
                job.finished = now - ago + 600
                model.feed.apply(job)
            }
            let state = ChatState(defaults: .scratch)
            state.trail.start(.group(.tasks))
            let window = ChatWindow.make(ChatView(model: model, state: state, character: nil))
            window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
            window.orderFrontRegardless()
            window.makeKey()
            defer { window.close() }
            ChatWindow.measureLights(window, into: state)
            try await Task.sleep(for: .milliseconds(800))
            let size = try #require(window.contentView?.bounds.size)
            // Two done cards, then the link's row 416 points down; its words are centred, this is 200 left of them.
            let at = NSPoint(x: size.width / 2 - 200, y: size.height - 416)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = try #require(NSEvent.mouseEvent(with: type, location: at, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
                window.sendEvent(event)
                try await Task.sleep(for: .milliseconds(80))
            }
            try await Task.sleep(for: .milliseconds(400))
            #expect(state.trail.top == .archived, "a click beside the words didn't open Archived: \(String(describing: state.trail.top))")
        }
    }

    /// A kind's name in the side panel opens its page, the one Home's chip opens (the owner's
    /// addition to Sangam's design, 2026-10-21); its chevron only folds it, and a folded group stays
    /// folded over the page.
    @Test func aGroupsNameOpensItsPageAndItsChevronFolds() async throws {
        try await withPanel(open: true) {
            let state = ChatState(defaults: .scratch)
            let window = ChatWindow.make(ChatView(model: model(), state: state, character: nil))
            window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
            window.orderFrontRegardless()
            window.makeKey()
            defer { window.close() }
            ChatWindow.measureLights(window, into: state)
            try await Task.sleep(for: .milliseconds(800))
            let height = try #require(window.contentView?.bounds.height)
            // Review PR's row, 159 points down: its name from 74, its chevron at 142, its count at the right.
            func click(_ x: CGFloat) async throws {
                for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    let event = try #require(NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: height - 159), modifierFlags: [],
                                                                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                                context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
                    window.sendEvent(event)
                    try await Task.sleep(for: .milliseconds(80))
                }
                try await Task.sleep(for: .milliseconds(500))
            }
            try await click(142)
            #expect(state.folded == ["review"] && state.trail.isHome, "the chevron didn't only fold: \(state.folded) \(state.trail)")
            try await click(142)
            #expect(state.folded.isEmpty, "the chevron didn't unfold")
            // The row past the chevron folds too, as the whole row does in Sangam's design.
            try await click(220)
            #expect(state.folded == ["review"] && state.trail.isHome, "the row past the chevron didn't fold: \(state.folded)")
            try await click(95)
            #expect(state.trail.top == .group(.review), "the name didn't open Review PR's page: \(state.trail)")
            #expect(state.folded == ["review"], "opening the page unfolded the group")
        }
    }
}
// Temporary: finds where the two cards' targets moved. Not committed.
