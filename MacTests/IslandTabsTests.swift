import Foundation
import Testing
@testable import Oby

@MainActor
struct IslandTabsTests {
    @Test func tabsHaveStableKeyboardShortcuts() {
        #expect(IslandTab.allCases.map(\.shortcut) == ["1", "2", "3"])
        #expect(IslandTab.allCases.map(\.title) == ["Home", "Chat", "Settings"])
    }

    @Test func lastTabIsRememberedAndNeedsYouOpensHome() {
        let key = IslandModel.tabKey
        let old = UserDefaults.standard.object(forKey: key)
        defer {
            if let old { UserDefaults.standard.set(old, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        UserDefaults.standard.removeObject(forKey: key)
        let folder = FileManager.default.temporaryDirectory.appending(path: "oby-island-tabs-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let desk = Desk(accounts: AccountStore(root: folder), store: JobStore(url: folder.appending(path: "oby.sqlite")))
        let model = IslandModel(desk: desk, feed: RunnerFeed(), availability: MacAvailability())
        model.select(.settings)
        #expect(model.openingTab == .settings)
        #expect(IslandModel(desk: desk, feed: RunnerFeed(), availability: MacAvailability()).tab == .settings)
        desk.cancel()
    }
}
