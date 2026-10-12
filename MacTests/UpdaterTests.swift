import Foundation
import Testing
@testable import Oby

/// Updates (#282): the version as the menu says it, the island's pill only once an update is
/// downloaded, a Restart that installs now, and a relaunch that waits for this Mac's check.
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

    @MainActor @Test func restartInstallsAStagedUpdateNow() {
        let updater = Updater()
        var installed = 0
        var resumed = 0
        updater.resume = { resumed += 1 }
        #expect(updater.pill == nil)
        // Sparkle downloaded it and would install on quit: Oby takes over, and Restart installs now.
        updater.staged("1.2.3") { installed += 1 }
        #expect(updater.pill == "Update ready · Restart")
        updater.install()
        #expect(installed == 1 && resumed == 0)
        // Sparkle's window took over: nothing left to offer, and Restart does nothing.
        updater.clear()
        #expect(updater.pill == nil)
        updater.install()
        #expect(installed == 1 && resumed == 0)
        // Found but not downloaded: the pill goes to Sparkle's window.
        updater.found(.init(version: "1.2.4", staged: false))
        #expect(updater.pill == "Update 1.2.4 available")
        updater.install()
        #expect(installed == 1 && resumed == 1)
    }

    @MainActor @Test func relaunchWaitsForTheCheckRunningHere() async throws {
        let updater = Updater()
        updater.pollInterval = .milliseconds(10)
        var busy = true
        var relaunched = 0
        updater.busy = { busy }
        updater.staged("1.2.3") {}
        // Sparkle is about to quit and relaunch while a check runs here: it waits, and goes once
        // the check ends.
        #expect(updater.shouldPostponeRelaunch { relaunched += 1 })
        #expect(updater.waiting && updater.pill == "Restarting after this check…")
        try await Task.sleep(for: .milliseconds(60))
        #expect(updater.waiting && relaunched == 0)
        // Restart clicked again meanwhile does nothing more.
        updater.install()
        busy = false
        for _ in 0..<300 where relaunched == 0 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(relaunched == 1 && !updater.waiting)
        // No check running: the relaunch goes now, without the handler.
        #expect(!updater.shouldPostponeRelaunch { relaunched += 1 })
        #expect(relaunched == 1 && !updater.waiting)
    }

    @MainActor @Test func clearingCancelsAWaitingRelaunch() async throws {
        let updater = Updater()
        updater.pollInterval = .milliseconds(10)
        var relaunched = 0
        updater.busy = { true }
        updater.staged("1.2.3") {}
        #expect(updater.shouldPostponeRelaunch { relaunched += 1 })
        #expect(updater.waiting)
        updater.clear()
        #expect(!updater.waiting && updater.pill == nil)
        try await Task.sleep(for: .milliseconds(60))
        #expect(relaunched == 0)
    }
}
