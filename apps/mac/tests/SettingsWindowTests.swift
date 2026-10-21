import AppKit
import Testing
@testable import Oby

/// Settings as pages in the window (docs/mac-design.md A1, B5): opened over Home from the side
/// panel's Settings section, the account menu and ⌘,, with no Settings window of its own.
@MainActor
struct SettingsWindowTests {
    @Test func pagesAreSangamsInHisOrder() {
        #expect(SettingsPage.allCases.map(\.label) == ["General", "Runner", "Remote access", "Accounts", "Models", "Connectors", "Obysphere", "Vault", "About"])
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

    /// Pair a device sends you to Remote access with its switch pointed at, then back to its own
    /// button; opening Settings any other way points at nothing.
    @Test func pairADevicePointsAtRemoteAccessThenBack() {
        let state = ChatState()
        let open = OpenSettingsPage(state: state, animated: false)
        open(.remote, spotlight: .remoteAccess)
        #expect(state.trail.top == .settings(.remote))
        #expect(open.spotlight == .remoteAccess)
        open(.runner, spotlight: .pairDevice)
        open.clear(.remoteAccess)
        #expect(open.spotlight == .pairDevice)
        open.clear(.pairDevice)
        #expect(open.spotlight == nil)
        open(.remote, spotlight: .remoteAccess)
        state.openSettings(.accounts)
        #expect(state.spotlight == nil)
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

    /// The usage panel's gear opens Accounts in its own window; the action is equal for the same
    /// window, so the box doesn't redraw for a new closure on every update.
    @Test func usageGearOpensAccountsInItsWindow() {
        let state = ChatState(), other = ChatState()
        let open = OpenSettingsPage(state: state, animated: false)
        #expect(open == OpenSettingsPage(state: state, animated: false))
        #expect(open != OpenSettingsPage(state: other, animated: false))
        open(.accounts)
        #expect(state.trail.top == .settings(.accounts))
        #expect(other.trail.isHome)
    }

    /// ⌘, stays: the app menu has one Settings… on it, which opens the window's Settings.
    @Test func commandCommaIsSettings() {
        let items = NSApp.mainMenu?.items.flatMap { $0.submenu?.items ?? [] } ?? []
        let comma = items.filter { $0.keyEquivalent == "," && $0.keyEquivalentModifierMask == .command }
        #expect(comma.map(\.title) == ["Settings…"])
    }
}
