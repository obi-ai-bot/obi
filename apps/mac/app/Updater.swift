import AppKit
import Observation
import Sparkle
import SwiftUI

/// Updates (#282): Sparkle reads the appcast (apps/mac/app/Info.plist, `SUFeedURL`) every 6 hours,
/// downloads a new version quietly and installs it when Oby quits. Once one is downloaded, Sparkle
/// hands Oby the installation (`willInstallUpdateOnQuit`), and the menu bar offers "Update ready ·
/// Restart", which installs it and relaunches Oby now, with no window. Check for Updates… in the
/// menus asks at once, with Sparkle's own window.
///
/// A relaunch never interrupts a check this Mac runs for the runner (apps/mac/app/MacChecks.swift): every
/// way an update ends in a relaunch, the pill, Sparkle's Install and Relaunch, or an install on
/// quit, goes through `shouldPostponeRelaunch`, which waits for the check to end.
///
/// A Release build starts the updater at launch. A Debug build from Xcode starts it only for Check
/// for Updates…, so it never replaces itself with a release quietly.
@Observable
final class Updater: NSObject {
    /// An update Sparkle found: `staged` once it's downloaded and ready to install.
    struct Offer: Equatable, Sendable {
        var version: String
        var staged: Bool
    }

    /// The update waiting, or nil.
    private(set) var offer: Offer?
    /// A relaunch is due while this Mac runs a check: it goes once the check ends.
    private(set) var waiting = false
    /// Whether this Mac is busy with what a relaunch would interrupt: a check for the runner.
    @ObservationIgnored var busy: () -> Bool = { false }
    /// Brings Sparkle's window to the update it found: it installs and relaunches from there.
    @ObservationIgnored var resume: () -> Void = {}
    /// How often a waiting relaunch looks whether the check ended.
    @ObservationIgnored var pollInterval: Duration = .seconds(2)
    /// Sparkle's handler that installs the staged update and relaunches now, with no window.
    @ObservationIgnored private var installNow: (() -> Void)?
    @ObservationIgnored private var controller: SPUStandardUpdaterController?
    @ObservationIgnored private var relaunch: Task<Void, Never>?

    /// "1.2.3 (45)": the version and the build number, as the menu and Settings › About say it.
    nonisolated static func version(short: String?, build: String?) -> String {
        let short = short?.trimmingCharacters(in: .whitespaces) ?? ""
        let build = build?.trimmingCharacters(in: .whitespaces) ?? ""
        switch (short.isEmpty, build.isEmpty) {
        case (false, false): return "\(short) (\(build))"
        case (false, true): return short
        case (true, false): return "build \(build)"
        case (true, true): return "unknown version"
        }
    }

    /// This build's version, from its Info.plist.
    static var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        return version(short: info["CFBundleShortVersionString"] as? String, build: info["CFBundleVersion"] as? String)
    }

    /// What the menu's update item says, or nil when there's nothing to offer: "Update ready · Restart"
    /// only once the update is downloaded.
    var pill: String? { Self.pill(offer, waiting: waiting) }

    nonisolated static func pill(_ offer: Offer?, waiting: Bool) -> String? {
        guard let offer else { return nil }
        guard offer.staged else { return "Update \(offer.version) available" }
        return waiting ? "Restarting after this check…" : "Update ready · Restart"
    }

    /// Starts Sparkle: scheduled checks from here on, once.
    func start() {
        guard controller == nil else { return }
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: self)
        self.controller = controller
        resume = { controller.checkForUpdates(nil) }
        controller.startUpdater()
    }

    /// Check for Updates…: Sparkle's window says what it finds, and installs it.
    func check() {
        start()
        resume()
    }

    /// The pill: installs the staged update and relaunches now. Sparkle asks `shouldPostponeRelaunch`
    /// first, so a check running on this Mac ends before Oby quits. An update that isn't downloaded
    /// yet goes to Sparkle's window instead.
    func install() {
        guard offer != nil, !waiting else { return }
        if let installNow {
            installNow()
        } else {
            resume()
        }
    }

    /// Sparkle found `offer`, or downloaded it: the menu shows it.
    func found(_ offer: Offer) {
        self.offer = offer
    }

    /// Sparkle downloaded `version` and would install it on quit: Oby takes over, and `handler`
    /// installs it and relaunches now.
    func staged(_ version: String, installNow handler: @escaping () -> Void) {
        installNow = handler
        offer = Offer(version: version, staged: true)
    }

    /// Sparkle is about to quit Oby and relaunch it: true to hold the relaunch until this Mac's
    /// check ends, when `handler` is called; false to go now.
    func shouldPostponeRelaunch(then handler: @escaping () -> Void) -> Bool {
        guard busy() else { return false }
        relaunch?.cancel()
        waiting = true
        relaunch = Task { [weak self] in
            while let self, !Task.isCancelled, busy() {
                try? await Task.sleep(for: pollInterval)
            }
            guard let self, !Task.isCancelled else { return }
            relaunch = nil
            waiting = false
            handler()
        }
        return true
    }

    /// Sparkle's own window took over, or the update session ended: nothing to offer.
    func clear() {
        relaunch?.cancel()
        relaunch = nil
        waiting = false
        offer = nil
        installNow = nil
    }
}

// Sparkle hands Oby the installation of a downloaded update, and asks before every relaunch.
extension Updater: SPUUpdaterDelegate {
    nonisolated func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem, immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        MainActor.assumeIsolated { staged(item.displayVersionString, installNow: immediateInstallHandler) }
        return true
    }

    nonisolated func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem, untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        MainActor.assumeIsolated { shouldPostponeRelaunch(then: installHandler) }
    }

    nonisolated func updater(_ updater: SPUUpdater, didAbortWithError error: any Error) {
        MainActor.assumeIsolated { clear() }
    }
}

// Sparkle's gentle reminders: a scheduled update is never a window over the user's work, only the
// menu's update item; Check for Updates… and the item bring Sparkle's window to it.
extension Updater: SPUStandardUserDriverDelegate {
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        false
    }

    nonisolated func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        guard !handleShowingUpdate else { return }
        let offer = Offer(version: update.displayVersionString, staged: state.stage != .notDownloaded)
        MainActor.assumeIsolated { found(offer) }
    }

    nonisolated func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        MainActor.assumeIsolated { clear() }
    }

    nonisolated func standardUserDriverWillFinishUpdateSession() {
        MainActor.assumeIsolated { clear() }
    }
}

/// Settings › About: the version, Check for Updates…, and how updates arrive.
struct AboutSettingsView: View {
    let updater: Updater

    var body: some View {
        SetGroup("Oby", footer: "Oby checks for updates every 6 hours, downloads them quietly and installs them when it quits. Once one is downloaded, the menu bar offers to restart now; if this Mac is running a check for the runner, the restart waits for it.") {
            SetRow("Version") { SetValue(Updater.version) }
            SetRow("") {
                Button("Check for Updates…") { updater.check() }.buttonStyle(.set)
                if let pill = updater.pill {
                    Button(pill) { updater.install() }
                        .buttonStyle(.set)
                        .disabled(updater.waiting)
                }
            }
        }
    }
}
