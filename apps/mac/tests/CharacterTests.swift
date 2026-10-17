import AppKit
import CoreGraphics
import Foundation
import SwiftUI
import Testing
import WebKit
@testable import Oby

/// Sangam's newer mascot (#499), as the app bundles it (character/package/build.sh) and the window drives it.
@MainActor
struct CharacterTests {
    /// The bundled page, loaded as the app loads it.
    static func page() async throws -> WebPage {
        var config = WebPage.Configuration()
        config.urlSchemeHandlers[URLScheme("oby")!] = CharacterFiles()
        let page = WebPage(configuration: config)
        for try await _ in page.load(URLRequest(url: URL(string: "oby://character/oby.html?size=1.25")!)) {}
        return page
    }

    static func js(_ page: WebPage, _ body: String, _ arguments: [String: Any] = [:]) async throws -> Any? {
        try await page.callJavaScript(body, arguments: arguments, contentWorld: .page)
    }

    @Test func bundledPageHasLoadingAndTheExpressionsTheAppsPlay() async throws {
        let page = try await Self.page()
        let states = try await Self.js(page, "return oby.states") as? [String]
        #expect(states == ["idle", "listening", "thinking", "working", "loading", "quiet"])
        let expressions = Set(try await Self.js(page, "return oby.expressions") as? [String] ?? [])
        // The states' expressions, and the iPhone's Home (apps/ios/app/Home.swift).
        for name in ["Listening", "Thinking", "Working", "Loading", "Agree", "Confused", "Hello", "Grin"] {
            #expect(expressions.contains(name), "\(name) isn't in the bundled page")
        }
        let api = try await Self.js(page, "return ['look', 'notice', 'attend'].every((f) => typeof oby[f] === 'function')") as? Bool
        #expect(api == true)
        // The playground stays out of what the app ships.
        let playground = try await Self.js(page, "return document.getElementById('ui') !== null || '__cube' in window") as? Bool
        #expect(playground == false)
    }

    @Test func leavingLoadingLetsItFinish() async throws {
        let page = try await Self.page()
        _ = try await Self.js(page, "oby.setState('loading', { now: true })")
        #expect(try await Self.js(page, "return oby.playing") as? String == "Loading")
        // The answer landed: Oby's next mood starts once Loading has run back together, not mid-melt.
        _ = try await Self.js(page, ObyCharacter.switching(from: "loading", to: "idle"), ["state": "idle"])
        #expect(try await Self.js(page, "return oby.state") as? String == "idle")
        #expect(try await Self.js(page, "return oby.playing") as? String == "Loading")
        // Any other mood switches at once.
        _ = try await Self.js(page, ObyCharacter.switching(from: "idle", to: "working"), ["state": "working"])
        #expect(try await Self.js(page, "return oby.state") as? String == "working")
        #expect(try await Self.js(page, "return oby.playing") as? String != "Loading")
    }

    @Test func talkingWhileItThinksListensAtOnce() async throws {
        let page = try await Self.page()
        _ = try await Self.js(page, "oby.setState('loading', { now: true })")
        #expect(try await Self.js(page, "return oby.playing") as? String == "Loading")
        // You hold the talk key while Oby thinks: it listens now, not after its dots run back together.
        _ = try await Self.js(page, ObyCharacter.switching(from: "loading", to: "listening"), ["state": "listening"])
        #expect(try await Self.js(page, "return oby.state") as? String == "listening")
        #expect(try await Self.js(page, "return oby.playing") as? String == "Listening")
    }

    /// The window keeps Oby's frame transparent until the page says it has drawn, so the bundled
    /// page has to say it. Hosted with the web view at opacity 0 (hidden, it would draw nothing and
    /// never be ready), in an ordered-front borderless panel.
    @Test func bundledPageSaysReadyOnceItDraws() async throws {
        let character = ObyCharacter()
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 136, height: 136), styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.ignoresMouseEvents = true
        panel.contentView = NSHostingView(rootView: WebView(character.page).webViewContentBackground(.hidden).opacity(0).frame(width: 136, height: 136))
        panel.orderFrontRegardless()
        defer { panel.orderOut(nil) }
        #expect(!character.ready)
        let deadline = Date.now.addingTimeInterval(15)
        while !character.ready, Date.now < deadline { try await Task.sleep(for: .milliseconds(50)) }
        #expect(character.ready, "the bundled page never sent ready")
    }

    @Test func obyShowsLoadingWhileTheBrainThinks() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "oby-character-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let desk = Desk(accounts: AccountStore(root: folder), store: JobStore(url: folder.appending(path: "oby.sqlite")))
        let model = IslandModel(desk: desk, feed: RunnerFeed(), availability: MacAvailability())
        #expect(model.mood == "idle")
        desk.talk = .thinking("What's left on #499?")
        #expect(model.mood == "loading")
        desk.talk = .reply("Two checks.")
        #expect(model.mood == "idle")
        model.listening = true
        #expect(model.mood == "listening")
    }
}
