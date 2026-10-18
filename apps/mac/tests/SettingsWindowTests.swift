import AppKit
import Testing
@testable import Oby

/// Settings as pages in the window (docs/mac-design.md A1, B5): opened over Home from the side
/// panel's Settings section, the account menu and ⌘,, with no Settings window of its own.
@MainActor
struct SettingsWindowTests {
    @Test func pagesAreSangamsInHisOrder() {
        #expect(SettingsPage.allCases.map(\.label) == ["General", "Runner", "Remote access", "Accounts", "Models", "Connectors", "Vault", "About"])
    }

    @Test func aPageOpensOverHomeWithThePanelOnSettings() {
        let state = ChatState()
        state.trail.start(.group(.review))
        state.openSettings(.accounts)
        #expect(state.trail.steps == [.settings(.accounts)])
        #expect(state.section == .settings)
    }

    @Test func settingsOpensOnGeneralUnlessOneOfItsPagesShows() {
        let state = ChatState()
        state.openSettings()
        #expect(state.trail.top == .settings(.general))
        state.openSettings(.models)
        state.openSettings()
        #expect(state.trail.top == .settings(.models))
    }

    @Test func theTrailNamesThePage() {
        let model = IslandModel(desk: Desk(), feed: RunnerFeed(), availability: MacAvailability())
        #expect(WindowLabels.label(.settings(.remote), model: model) == "Remote access")
    }

    @Test func escGoesBackHome() {
        let state = ChatState()
        state.openSettings(.vault)
        state.trail.back()
        #expect(state.trail.isHome)
    }

    /// The account menu's head: your name, then the Oby account's email once Remote access signed
    /// in, else this Mac's name.
    @Test func accountMenuSaysWhoYouAre() {
        #expect(SidebarSections.accountLine(email: "you@example.com", mac: "Studio") == "you@example.com")
        #expect(SidebarSections.accountLine(email: nil, mac: "Studio") == "Studio")
        #expect(SidebarSections.accountLine(email: "", mac: nil) == "This Mac")
    }

    /// ⌘, stays: the app menu has one Settings… on it, which opens the window's Settings.
    @Test func commandCommaIsSettings() {
        let items = NSApp.mainMenu?.items.flatMap { $0.submenu?.items ?? [] } ?? []
        let comma = items.filter { $0.keyEquivalent == "," && $0.keyEquivalentModifierMask == .command }
        #expect(comma.map(\.title) == ["Settings…"])
    }
}
