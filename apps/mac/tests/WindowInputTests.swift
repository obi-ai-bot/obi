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
            let state = ChatState()
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
                let state = ChatState()
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
}
