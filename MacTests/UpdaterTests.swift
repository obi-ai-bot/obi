import Foundation
import Testing
@testable import Oby

/// Updates (#282): the version as the menu says it, and the island's pill only once an update is
/// downloaded, with a restart that waits for this Mac's check.
struct UpdaterTests {
    @Test func versionReadsLikeTheMenu() {
        #expect(Updater.version(short: "1.2.3", build: "45") == "1.2.3 (45)")
        #expect(Updater.version(short: "1.2.3", build: "") == "1.2.3")
        #expect(Updater.version(short: " 1.2.3 ", build: nil) == "1.2.3")
        #expect(Updater.version(short: nil, build: "45") == "build 45")
        #expect(Updater.version(short: nil, build: nil) == "unknown version")
    }

    @MainActor @Test func thisBuildHasAVersion() {
        // The test host is Oby.app: MARKETING_VERSION and CURRENT_PROJECT_VERSION are in its Info.plist.
        #expect(Updater.version.contains("("))
        #expect(Updater.version != "unknown version")
    }

    @Test func pillShowsOnlyWhenAnUpdateIsStaged() {
        #expect(Updater.pill(nil, waiting: false) == nil)
        #expect(Updater.pill(nil, waiting: true) == nil)
        #expect(Updater.pill(.init(version: "1.2.3", staged: false), waiting: false) == "Update 1.2.3 available")
        #expect(Updater.pill(.init(version: "1.2.3", staged: true), waiting: false) == "Update ready · Restart")
        #expect(Updater.pill(.init(version: "1.2.3", staged: true), waiting: true) == "Restarting after this check…")
    }

    @MainActor @Test func restartWaitsForTheCheckRunningHere() async throws {
        let updater = Updater()
        updater.pollInterval = .milliseconds(10)
        var busy = true
        var resumed = 0
        updater.busy = { busy }
        updater.resume = { resumed += 1 }
        #expect(updater.pill == nil)
        updater.found(.init(version: "1.2.3", staged: false))
        #expect(updater.pill == "Update 1.2.3 available")
        updater.found(.init(version: "1.2.3", staged: true))
        #expect(updater.pill == "Update ready · Restart")
        // Restart while a check runs here: it waits, and goes once the check ends.
        updater.install()
        #expect(updater.waiting && resumed == 0)
        try await Task.sleep(for: .milliseconds(60))
        #expect(updater.waiting && resumed == 0)
        busy = false
        for _ in 0..<300 where resumed == 0 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(resumed == 1 && !updater.waiting)
        // Sparkle's window took over: nothing left to offer.
        updater.clear()
        #expect(updater.pill == nil && !updater.waiting)
        // Not downloaded yet: the pill goes to Sparkle's window right away, check or no check.
        busy = true
        updater.found(.init(version: "1.2.4", staged: false))
        updater.install()
        #expect(resumed == 2 && !updater.waiting)
    }

    @MainActor @Test func clearingCancelsAWaitingRestart() async throws {
        let updater = Updater()
        updater.pollInterval = .milliseconds(10)
        var resumed = 0
        updater.busy = { true }
        updater.resume = { resumed += 1 }
        updater.found(.init(version: "1.2.3", staged: true))
        updater.install()
        #expect(updater.waiting)
        updater.clear()
        #expect(!updater.waiting && updater.pill == nil)
        try await Task.sleep(for: .milliseconds(60))
        #expect(resumed == 0)
    }
}
