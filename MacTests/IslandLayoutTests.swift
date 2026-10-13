import CoreGraphics
import Foundation
import Testing
@testable import Oby

/// No words beside or under the camera (#150): on a notched screen, every text frame stays clear of
/// the cutout, and on any screen it fits inside the island.
struct IslandLayoutTests {
    struct Screen: CustomStringConvertible {
        var width: CGFloat
        var notch: CGRect?
        var description: String { notch.map { "notch \(Int($0.width))" } ?? "no notch" }
    }

    static let screens = [
        // The 14-inch MacBook Pro, and the 15-inch MacBook Air the issue was seen on (cutout at x 751–959).
        Screen(width: 1512, notch: CGRect(x: (1512 - 184) / 2, y: 0, width: 184, height: 32)),
        Screen(width: 1710, notch: CGRect(x: 751, y: 0, width: 208, height: 37)),
        Screen(width: 1920, notch: nil),
    ]
    static let states: [IslandState] = [.compact, .peek, .open, .listening]
    /// The busy summary seen cut on the Air (#191).
    static let busy = "2 agents are working. 1 job is ready to publish, 1 job failed, 3 jobs need your review, 2 jobs have questions waiting for you."
    static let lines = [
        "6 agents are working · 1 needs your review, 1 job wasn't published, 2 questions are waiting for you",
        busy,
        String(repeating: busy + " ", count: 4),
        "1 agent is working.",
        Summary.quiet,
    ]

    static func layout(_ state: IslandState, on screen: Screen, line: String = IslandLayoutTests.lines[0]) -> IslandLayout {
        IslandLayout.of(state, screenWidth: screen.width, notch: screen.notch, barHeight: 24, line: line, openHeight: 240)
    }

    @MainActor @Test func islandChatUsesTheWindowsSharedThread() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "oby-chat-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let desk = Desk(accounts: AccountStore(root: folder), store: JobStore(url: folder.appending(path: "oby.sqlite")))
        desk.makeBrain = { _, _ in [] }
        let feed = RunnerFeed()
        let model = IslandModel(desk: desk, feed: feed)
        let reply = Turn(id: "remote", who: .oby, text: "Hello from the runner")
        feed.conversation.apply(reply)
        #expect(model.recentTurns.last == reply && model.unreadReply)
        model.markChatRead()
        #expect(!model.unreadReply)
        model.sendChat("   \n")
        #expect(desk.turns.isEmpty)
        model.sendChat("Hello from the notch")
        #expect(feed.conversation.thread(with: desk.turns).last?.text == "Hello from the notch")
        #expect(model.recentTurns == model.thread)
        desk.cancel()
    }

    @Test(arguments: screens, states)
    func noTextUnderTheCamera(screen: Screen, state: IslandState) {
        for line in Self.lines {
            let layout = Self.layout(state, on: screen, line: line)
            let island = CGRect(origin: .zero, size: layout.size)
            #expect(!layout.texts.isEmpty)
            #expect((1...IslandLayout.maxLines).contains(layout.lines))
            for text in layout.texts {
                #expect(island.contains(text), "\(text) leaves the island \(island)")
                if let notch = layout.notch {
                    #expect(text.intersection(notch).isEmpty, "\(text) runs under the camera \(notch)")
                }
            }
        }
    }

    /// No band of padding under the open island's content (#322): it runs to the bottom edge.
    @Test(arguments: screens)
    func theOpenContentReachesTheBottom(screen: Screen) throws {
        let open = Self.layout(.open, on: screen)
        let content = try #require(open.content)
        #expect(content.maxY == open.size.height)
        #expect(try #require(open.insets).bottom == 0)
        #expect(content.minY > 0 && content.width > 0)
    }

    @Test(arguments: screens.filter { $0.notch != nil })
    func theCutoutIsWhereTheScreenHasIt(screen: Screen) throws {
        // Centered on the screen, the island has the camera at its middle.
        for state in Self.states {
            let layout = Self.layout(state, on: screen)
            let notch = try #require(layout.notch)
            #expect(notch.width == screen.notch?.width)
            #expect(abs(notch.midX - layout.size.width / 2) < 1)
        }
    }

    @Test(arguments: screens.filter { $0.notch != nil })
    func hoveringDropsTheLineBelowTheCamera(screen: Screen) throws {
        let notch = try #require(screen.notch)
        let compact = Self.layout(.compact, on: screen)
        let peek = Self.layout(.peek, on: screen)
        let line = try #require(peek.line)
        #expect(peek.lineBelow)
        #expect(line.minY >= notch.height)
        #expect(peek.size.height > compact.size.height)
        // The wings keep Oby and the agent count, as when closed.
        #expect(peek.character == compact.character)
        let count = try #require(peek.count)
        let cutout = try #require(peek.notch)
        #expect(count.minX >= cutout.maxX)
        #expect(count.maxX == peek.size.width - 16)
    }

    @Test func theClosedIslandIsAsBefore() throws {
        let air = Self.layout(.compact, on: Self.screens[1])
        #expect(air.size == CGSize(width: 208 + 2 * 52, height: 37))
        #expect(air.radius == 12)
        #expect(air.character == CGRect(x: 8, y: -3, width: 43, height: 43))
        #expect(try #require(air.count).maxX == air.size.width - 16)
        #expect(air.line == nil && air.content == nil)

        let plain = Self.layout(.compact, on: Self.screens[2])
        #expect(plain.size == CGSize(width: 180, height: 24))
        #expect(try #require(plain.count).maxX == 180 - 16)
    }

    @Test func withoutANotchTheHoverPillIsUnchanged() throws {
        let screen = Self.screens[2]
        let peek = Self.layout(.peek, on: screen, line: "1 agent is working.")
        #expect(peek.size == CGSize(width: 180 + 320, height: 24 + 6))
        #expect(peek.lines == 1)
        let quiet = Self.layout(.peek, on: screen, line: Summary.quiet)
        #expect(quiet.size.width == 320)
        #expect(peek.radius == 18)
        #expect(!peek.lineBelow)
        #expect(peek.count == nil)
        // One row: Oby's name after the character, the line trailing 14 points from the edge.
        let line = try #require(peek.line)
        #expect(line.minX == peek.character.maxX + 4)
        #expect(line.maxX == peek.size.width - 14)
        #expect(line.minY == 0 && line.height == peek.size.height)
    }

    @Test(arguments: screens)
    func aLongHoverLineTakesTwoLines(screen: Screen) throws {
        let short = Self.layout(.peek, on: screen, line: "1 agent is working.")
        let long = Self.layout(.peek, on: screen, line: Self.busy)
        #expect(short.lines == 1)
        #expect(long.lines == 2)
        #expect(long.size.width == short.size.width)
        #expect(long.size.height == short.size.height + IslandLayout.lineHeight)
        let shortLine = try #require(short.line)
        let longLine = try #require(long.line)
        #expect(longLine.height == shortLine.height + IslandLayout.lineHeight)
        #expect(longLine.minY == shortLine.minY)
        // Past two lines the line is cut, and the island grows no further.
        let endless = Self.layout(.peek, on: screen, line: String(repeating: Self.busy + " ", count: 4))
        #expect(endless.lines == 2)
        #expect(endless.size == long.size)
    }

    @Test(arguments: screens)
    func aQuietHoverKeepsTodaysHeight(screen: Screen) {
        let quiet = Self.layout(.peek, on: screen, line: Summary.quiet)
        let top = screen.notch?.height ?? 24
        #expect(quiet.lines == 1)
        #expect(quiet.size.height == top + (screen.notch == nil ? 6 : 10 + IslandLayout.row))
    }

    @Test func measuringWrapsWhereTheRowEnds() {
        #expect(IslandLayout.lines(of: Summary.quiet, width: 400) == 1)
        #expect(IslandLayout.lines(of: Self.busy, width: 600) == 2)
        #expect(IslandLayout.lines(of: Self.busy, width: 100) > 2)
        #expect(IslandLayout.lines(of: "", width: 400) == 1)
    }

    @Test(arguments: screens)
    func openAndListeningStartBelowTheTop(screen: Screen) throws {
        let top = screen.notch?.height ?? 24
        #expect(try #require(Self.layout(.open, on: screen).content).minY == top + 10)
        #expect(try #require(Self.layout(.listening, on: screen).content).minY == top + 6)
    }
}
