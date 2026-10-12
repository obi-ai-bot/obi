import Foundation
import Observation
import OSLog
import ServiceManagement

/// The runner on this Mac (#283), as a login item: `oby-runner` from the app bundle
/// (Contents/Helpers/oby-runner), which launchd starts at login and keeps running while the
/// window is closed, registered with `SMAppService` from the bundle's own plist
/// (Contents/Library/LaunchAgents/com.deskree.oby.runner.plist, Runner/com.deskree.oby.runner.plist
/// in the repository). Settings › Runner turns it on with "This Mac" and off with a remote runner.
@Observable
final class RunnerLoginItem {
    static let plist = "com.deskree.oby.runner.plist"
    static let label = "com.deskree.oby.runner"
    /// Where the bundle keeps the plist and the executable, from its root.
    static let plistPath = "Contents/Library/LaunchAgents/" + plist
    static let helperPath = "Contents/Helpers/oby-runner"

    private(set) var status: SMAppService.Status
    /// Why the last register or unregister failed, or nil.
    private(set) var problem: String?
    @ObservationIgnored private let service: SMAppService

    init(service: SMAppService = .agent(plistName: RunnerLoginItem.plist)) {
        self.service = service
        status = service.status
    }

    /// Turns the runner on: it starts now and at every login. macOS may want the user's approval
    /// first (System Settings › General › Login Items): `needsApproval` says so, and `openSettings` goes there.
    func register() {
        do {
            try service.register()
            problem = nil
        } catch {
            problem = error.localizedDescription
            Logger.feed.error("registering the runner login item failed: \(error.localizedDescription, privacy: .public)")
        }
        refresh()
    }

    /// Turns it off: launchd stops the runner, and it no longer starts at login. Its files stay.
    func unregister() {
        do {
            try service.unregister()
            problem = nil
        } catch {
            problem = error.localizedDescription
            Logger.feed.error("unregistering the runner login item failed: \(error.localizedDescription, privacy: .public)")
        }
        refresh()
    }

    func refresh() { status = service.status }

    var isOn: Bool { status == .enabled }
    var needsApproval: Bool { status == .requiresApproval }

    /// Settings › Runner's word for it.
    var line: String {
        switch status {
        case .enabled: "Runs at login"
        case .requiresApproval: "Waiting for your approval in System Settings › Login Items"
        case .notFound: "Not in this build of Oby"
        case .notRegistered: "Off"
        @unknown default: "Off"
        }
    }

    static func openSettings() { SMAppService.openSystemSettingsLoginItems() }

    /// What's missing from `bundle` for the login item to work: the plist, the executable, or the
    /// executable's permission to run. Empty when the build bundled everything (MacTests check it).
    static func missing(in bundle: Bundle) -> [String] {
        var missing: [String] = []
        let files = FileManager.default
        let plist = bundle.bundleURL.appending(path: plistPath)
        let helper = bundle.bundleURL.appending(path: helperPath)
        if !files.fileExists(atPath: plist.path) { missing.append(plistPath) }
        if !files.fileExists(atPath: helper.path) { missing.append(helperPath) }
        else if !files.isExecutableFile(atPath: helper.path) { missing.append("\(helperPath) isn't executable") }
        return missing
    }
}
