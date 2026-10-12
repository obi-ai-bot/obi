import AppKit
import Observation
import Sparkle
import SwiftUI

/// Updates (#282): Sparkle reads the appcast (Mac/Info.plist, `SUFeedURL`) every 6 hours,
/// downloads a new version quietly and installs it when Oby quits. Once one is downloaded, the
/// island offers "Update ready · Restart", which installs it and relaunches Oby now, and Check for
/// Updates… in the menus asks at once, with Sparkle's own window. A restart never interrupts a
/// check this Mac runs for the runner (Mac/MacChecks.swift): it waits for the check to end.
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
    /// Restart was clicked while this Mac ran a check: it restarts once the check ends.
    private(set) var waiting = false
    /// Whether this Mac is busy with what a restart would interrupt: a check for the runner.
    @ObservationIgnored var busy: () -> Bool = { false }
    /// Brings Sparkle's window to the update it found: it installs and relaunches from there.
    @ObservationIgnored var resume: () -> Void = {}
    /// How often a waiting restart looks whether the check ended.
    @ObservationIgnored var pollInterval: Duration = .seconds(2)
    @ObservationIgnored private var controller: SPUStandardUpdaterController?
    @ObservationIgnored private var restart: Task<Void, Never>?

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

    /// What the island's pill says, or nil when there's nothing to offer: "Update ready · Restart"
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
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: self)
        self.controller = controller
        resume = { controller.checkForUpdates(nil) }
        controller.startUpdater()
    }

    /// Check for Updates…: Sparkle's window says what it finds, and installs it.
    func check() {
        start()
        resume()
    }

    /// The pill: installs the staged update and relaunches, once no check runs on this Mac. An
    /// update that isn't downloaded yet goes to Sparkle's window right away.
    func install() {
        guard let offer, restart == nil else { return }
        guard offer.staged, busy() else {
            resume()
            return
        }
        waiting = true
        restart = Task { [weak self] in
            while let self, !Task.isCancelled, busy() {
                try? await Task.sleep(for: pollInterval)
            }
            guard let self, !Task.isCancelled else { return }
            restart = nil
            waiting = false
            resume()
        }
    }

    /// Sparkle found `offer`, or downloaded it: the island shows it.
    func found(_ offer: Offer) {
        self.offer = offer
    }

    /// Sparkle's own window took over, or the update session ended: nothing to offer.
    func clear() {
        restart?.cancel()
        restart = nil
        waiting = false
        offer = nil
    }
}

// Sparkle's gentle reminders: a scheduled update is never a window over the user's work, only the
// island's pill; Check for Updates… and the pill bring Sparkle's window to it.
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
        Form {
            Section {
                LabeledContent("Version", value: Updater.version)
                Button("Check for Updates…") { updater.check() }
                if let pill = updater.pill {
                    Button(pill) { updater.install() }
                        .disabled(updater.waiting)
                }
            } header: {
                Text("Oby")
            } footer: {
                Text("Oby checks for updates every 6 hours, downloads them quietly and installs them when it quits. Once one is downloaded, the island offers to restart; if this Mac is running a check for the runner, the restart waits for it.")
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
    }
}
