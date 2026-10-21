import Foundation
import Observation
import OSLog
import Security
import ServiceManagement

/// The runner on this Mac: obid, Oby's engine, as a login item (the owner's decision of 2026-10-18:
/// open the app and the engine runs, no terminal, no install.sh). `obid` from the app bundle
/// (Contents/Helpers/obid), which launchd starts at login and keeps running while the window is
/// closed, registered with `SMAppService` from the bundle's own plist
/// (Contents/Library/LaunchAgents/com.deskree.oby.obid.plist, apps/mac/app/Tools/com.deskree.oby.obid.plist
/// in the repository). Settings › Runner turns it on with "This Mac" and off with a remote runner.
///
/// Two older setups give way to it: the Swift runner (`oby-runner`), which older builds registered
/// and which wanted the same ports, is unregistered; and an obid installed with install.sh, under
/// its own label, keeps running until the person moves it into Oby (`moveFromScript`).
@Observable
final class RunnerLoginItem {
    static let plist = "com.deskree.oby.obid.plist"
    /// Not install.sh's `com.deskree.obid`: macOS's background-task records keep a label tied to the
    /// file that first used it, and an app agent under install.sh's label then never starts (seen
    /// 2026-10-18: "Missing container for matching BTMItem", exit 78).
    static let label = "com.deskree.oby.obid"
    /// install.sh's label for obid's launch agent.
    static let scriptLabel = "com.deskree.obid"
    /// Where the bundle keeps the plist and the executable, from its root.
    static let plistPath = "Contents/Library/LaunchAgents/" + plist
    static let helperPath = "Contents/Helpers/obid"
    /// The Swift runner's item, which older builds registered: the bundle keeps only its plist, so
    /// it can be unregistered.
    static let swiftRunnerPlist = "com.deskree.oby.runner.plist"

    private(set) var status: SMAppService.Status
    /// Why the last register, unregister or move failed, or nil.
    private(set) var problem: String?
    /// obid's launch agent as install.sh wrote it, when it's there: it runs instead of the app's.
    private(set) var byScript: Bool
    @ObservationIgnored private let service: SMAppService
    @ObservationIgnored private let swiftRunner: SMAppService
    @ObservationIgnored private let scriptAgent: URL

    init(service: SMAppService = .agent(plistName: RunnerLoginItem.plist),
         swiftRunner: SMAppService = .agent(plistName: RunnerLoginItem.swiftRunnerPlist),
         scriptAgent: URL = RunnerLoginItem.scriptAgentURL) {
        self.service = service
        self.swiftRunner = swiftRunner
        self.scriptAgent = scriptAgent
        status = service.status
        byScript = FileManager.default.fileExists(atPath: scriptAgent.path)
    }

    /// `~/Library/LaunchAgents/com.deskree.obid.plist`, where install.sh puts obid's launch agent.
    static var scriptAgentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/LaunchAgents/\(scriptLabel).plist")
    }

    /// Turns the engine on: it starts now and at every login. macOS may want the user's approval
    /// first (System Settings › General › Login Items): `needsApproval` says so, and `openSettings`
    /// goes there. Not while install.sh's obid runs: that one serves this Mac until it's moved.
    func register() {
        refresh()
        guard !byScript else { return }
        guard Self.mayRegister() else {
            problem = Self.moveToApplications
            return
        }
        retireSwiftRunner()
        do {
            try service.register()
            problem = nil
        } catch {
            problem = error.localizedDescription
            Logger.feed.error("registering obid's login item failed: \(error.localizedDescription, privacy: .public)")
        }
        refresh()
    }

    /// Turns it off: launchd stops obid, and it no longer starts at login. Its files stay.
    func unregister() {
        do {
            if service.status == .enabled || service.status == .requiresApproval { try service.unregister() }
            problem = nil
        } catch {
            problem = error.localizedDescription
            Logger.feed.error("unregistering obid's login item failed: \(error.localizedDescription, privacy: .public)")
        }
        refresh()
    }

    /// At launch: the Swift runner an older build registered goes, and with "This Mac" on the
    /// engine is registered when nothing else serves this Mac. A registration macOS kept from an
    /// older signature can outlive the app it came from while launchd refuses the new obid ("spawn
    /// failed", exit 78, seen 2026-10-20 after #790 moved the signing team; "Launch Constraint
    /// Violation", seen the same day when the Developer ID 0.2.0 replaced an Apple Development
    /// build of the same team): it's registered again once when obid neither answers nor runs. A
    /// change of the app's team or kind of certificate since the last launch is only noted in the
    /// reason, never a re-register on its own (`atLaunch`). Not from
    /// a copy outside Applications (`mayRegister`): its registration would point at a folder that
    /// vanishes.
    func reconcile(onThisMac: Bool) {
        retireSwiftRunner()
        refresh()
        let signing = Self.signing()
        // Both recorded at every launch, so neither may skip the other.
        let teamChanged = Self.changed(signing.team, key: Self.teamKey)
        let kindChanged = Self.changed(signing.kind, key: Self.kindKey)
        let mayRegister = Self.mayRegister()
        guard onThisMac, !byScript, mayRegister else { return }
        let status = status
        let signingChanged = teamChanged || kindChanged
        Task {
            let checks = status != .notRegistered && status != .requiresApproval
            let runs = checks ? await Self.obidRuns() : true
            switch Self.atLaunch(onThisMac: onThisMac, byScript: byScript, mayRegister: mayRegister, status: status,
                                 signingChanged: signingChanged, runs: runs) {
            case .nothing: break
            case .register: register()
            case .reregister(let why): reregister(because: why)
            }
        }
    }

    /// What launch does about obid's login item.
    nonisolated enum AtLaunch: Equatable { case nothing, register, reregister(String) }

    /// Registers when nothing is; registers again when obid doesn't run (`runs`), whatever macOS
    /// says of the registration (`.enabled`, or `.notFound` for one it lost track of). A signature
    /// change alone never does: Debug (Apple Development) and the installed app (Developer ID)
    /// share one bundle ID, so switching between them would take a working obid down at every
    /// launch; a launch constraint launchd enforces shows as obid not running anyway. Waiting for
    /// approval: nothing, that's the user's step, and Settings › Runner shows it. A copy that may
    /// not register (`mayRegister`) leaves the registration alone.
    nonisolated static func atLaunch(onThisMac: Bool, byScript: Bool, mayRegister: Bool, status: SMAppService.Status,
                                     signingChanged: Bool, runs: Bool) -> AtLaunch {
        guard onThisMac, !byScript, mayRegister else { return .nothing }
        switch status {
        case .requiresApproval: return .nothing
        case .notRegistered: return .register
        case _ where !runs:
            return .reregister("obid doesn't answer on 127.0.0.1:\(LocalRunner.port) and launchd doesn't run it"
                + (signingChanged ? ", and Oby's signing team or kind of certificate changed since the last launch" : ""))
        default: return .nothing
        }
    }

    /// The app's signing team, and its kind of certificate, at the last launch (`signing`).
    static let teamKey = "obidSigningTeam"
    static let kindKey = "obidSigningKind"
    /// At most one re-register per launch, so a registration that keeps failing never loops.
    private static var reregistered = false

    private func reregister(because why: String) {
        guard !Self.reregistered else { return }
        Self.reregistered = true
        Logger.feed.notice("registering obid's login item again: \(why, privacy: .public)")
        // Whatever the status says: a registration macOS reports `.notFound` can still be launchd's.
        do { try service.unregister() } catch {
            Logger.feed.notice("unregistering obid's login item before registering it again: \(error.localizedDescription, privacy: .public)")
        }
        register()
    }

    /// Records `now` under `key` and says whether it differs from the last launch's. Nothing on
    /// either side (ad hoc, unreadable, or a build before this one) is no change: the health check
    /// alone decides.
    static func changed(_ now: String?, key: String, in defaults: UserDefaults = .standard) -> Bool {
        let last = defaults.string(forKey: key)
        if let now { defaults.set(now, forKey: key) }
        return now != nil && last != nil && now != last
    }

    /// The team ID the running app is signed with, and the kind of its certificate ("Developer ID
    /// Application", "Apple Development": launchd's validation category follows it), each nil when
    /// ad hoc or unreadable.
    nonisolated static func signing() -> (team: String?, kind: String?) {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var info: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let info = info as? [String: Any]
        else { return (nil, nil) }
        let leaf = (info[kSecCodeInfoCertificates as String] as? [SecCertificate])?.first
        return (info[kSecCodeInfoTeamIdentifier as String] as? String,
                leaf.flatMap { SecCertificateCopySubjectSummary($0) as String? }.flatMap(kind(of:)))
    }

    /// "Developer ID Application" from "Developer ID Application: Deskree Technologies Inc. (3UV9W5SV7W)".
    nonisolated static func kind(of summary: String) -> String? {
        summary.range(of: ": ").map { String(summary[..<$0.lowerBound]) }
    }

    /// Whether this copy may register obid: the installed app only from /Applications or
    /// ~/Applications. Anywhere else (App Translocation's temporary copy of an app opened,
    /// quarantined, from the disk image or Downloads; a mounted disk image; an old copy in
    /// Downloads) the registration would point at a copy that goes away, and Sparkle can't
    /// replace it: Oby asks to be moved to Applications instead (ObyApp). A Debug build runs from
    /// DerivedData, so it may register from anywhere but those temporary places.
    nonisolated static func mayRegister(_ path: String = Bundle.main.bundlePath,
                                        home: String = FileManager.default.homeDirectoryForCurrentUser.path,
                                        debug: Bool = isDebug) -> Bool {
        let path = URL(filePath: path).standardizedFileURL.path
        if path.contains("/AppTranslocation/") || path.hasPrefix("/Volumes/") { return false }
        if debug { return true }
        return ["/Applications/", URL(filePath: home).appending(path: "Applications").path + "/"].contains { path.hasPrefix($0) }
    }

    #if DEBUG
    nonisolated static let isDebug = true
    #else
    nonisolated static let isDebug = false
    #endif

    static let moveToApplications = "Oby is running from outside Applications, so its engine can’t start and updates can’t install. Quit Oby, drag it into Applications, and open it from there."

    /// Whether obid runs: it answers on 127.0.0.1 within about 5 seconds, or launchd says it's
    /// running (still starting). A job launchd lacks, or one it couldn't spawn, doesn't run.
    nonisolated static func obidRuns() async -> Bool {
        for second in 0..<5 {
            var request = URLRequest(url: LocalRunner.url)
            request.timeoutInterval = 1
            // Any answer, even 401 without the token, means obid listens.
            if (try? await URLSession.shared.data(for: request)) != nil { return true }
            if second < 4 { try? await Task.sleep(for: .seconds(1)) }
        }
        return launchd(label)?.split(separator: "\n").contains { $0.trimmingCharacters(in: .whitespaces) == "state = running" } == true
    }

    /// `launchctl print` for `label` in this user's GUI domain, or nil when launchd hasn't got it.
    nonisolated static func launchd(_ label: String) -> String? {
        let print = Process()
        let out = Pipe()
        print.executableURL = URL(filePath: "/bin/launchctl")
        print.arguments = ["print", "gui/\(getuid())/\(label)"]
        print.standardOutput = out
        print.standardError = FileHandle.nullDevice
        guard (try? print.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        print.waitUntilExit()
        return print.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
    }

    /// Unregisters the Swift runner's login item when an older build left it registered.
    private func retireSwiftRunner() {
        guard swiftRunner.status == .enabled || swiftRunner.status == .requiresApproval else { return }
        do {
            try swiftRunner.unregister()
            Logger.feed.notice("unregistered the Swift runner's login item: obid replaces it")
        } catch {
            Logger.feed.error("unregistering the Swift runner's login item failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Why install.sh's obid can't be moved as it is, or nil: the app's obid reads
    /// `~/Library/Application Support/Oby/obid/config.json`, so one started with another
    /// `--config` would lose its settings. `arguments` are its launch agent's ProgramArguments.
    static func cantMove(arguments: [String], home: URL) -> String? {
        guard let flag = arguments.firstIndex(where: { $0 == "--config" || $0.hasPrefix("--config=") }) else { return nil }
        let given = arguments[flag] == "--config"
            ? (flag + 1 < arguments.count ? arguments[flag + 1] : "")
            : String(arguments[flag].dropFirst("--config=".count))
        let expected = home.appending(path: "Library/Application Support/Oby/obid/config.json").path
        return URL(filePath: given).standardizedFileURL.path == URL(filePath: expected).standardizedFileURL.path ? nil
            : "install.sh's obid uses \(given). Move that file to \(expected) first, so Oby's own obid keeps its settings."
    }

    /// Moves install.sh's obid into Oby: stops its launch agent, removes the agent's file, and
    /// registers the app's obid, which uses the same configuration, home, jobs and token.
    func moveFromScript() {
        // Before install.sh's obid stops: from here the app's obid couldn't take over.
        guard Self.mayRegister() else {
            problem = Self.moveToApplications
            return
        }
        guard byScript else { return register() }
        do {
            let data = try Data(contentsOf: scriptAgent)
            let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
            if let why = Self.cantMove(arguments: plist?["ProgramArguments"] as? [String] ?? [],
                                       home: FileManager.default.homeDirectoryForCurrentUser) {
                problem = why
                return
            }
            let stop = Process()
            stop.executableURL = URL(filePath: "/bin/launchctl")
            stop.arguments = ["bootout", "gui/\(getuid())/\(Self.scriptLabel)"]
            try stop.run()
            stop.waitUntilExit()
            // Its agent goes only once it's stopped: else both would want the same ports. Still
            // stopping (EINPROGRESS): asked for a few seconds whether launchd still has it.
            var stopped = Self.bootout(stop.terminationStatus)
            if stopped == .stopping {
                for _ in 0..<25 where Self.loaded(Self.scriptLabel) {
                    Thread.sleep(forTimeInterval: 0.2)
                }
                stopped = Self.loaded(Self.scriptLabel) ? .failed : .stopped
            }
            guard stopped == .stopped else {
                problem = "install.sh's obid didn't stop (launchctl bootout said \(stop.terminationStatus)), so it keeps running. Try again in a moment."
                refresh()
                return
            }
            if let program = (plist?["ProgramArguments"] as? [String])?.first {
                dropScriptFolders(program: program)
            }
            try FileManager.default.removeItem(at: scriptAgent)
            Logger.feed.notice("moved install.sh's obid into Oby (launchctl bootout said \(stop.terminationStatus))")
        } catch {
            problem = "Couldn't stop install.sh's obid: \(error.localizedDescription)"
            refresh()
            return
        }
        refresh()
        register()
    }

    /// What `launchctl bootout` left install.sh's obid as.
    enum Bootout: Equatable { case stopped, stopping, failed }

    /// Stopped: it stopped it (0), or it wasn't loaded (3, ESRCH; 113, could not find the service).
    /// Stopping: 36, EINPROGRESS, it's still being stopped. Anything else failed.
    static func bootout(_ status: Int32) -> Bootout {
        switch status {
        case 0, 3, 113: .stopped
        case 36: .stopping
        default: .failed
        }
    }

    /// Whether launchd still has `label` in this user's GUI domain (`launchctl print` finds it).
    static func loaded(_ label: String) -> Bool {
        let print = Process()
        print.executableURL = URL(filePath: "/bin/launchctl")
        print.arguments = ["print", "gui/\(getuid())/\(label)"]
        print.standardOutput = FileHandle.nullDevice
        print.standardError = FileHandle.nullDevice
        guard (try? print.run()) != nil else { return true }
        print.waitUntilExit()
        return print.terminationStatus == 0
    }

    /// The configuration without the keys that point into install.sh's own folder (`prefix`,
    /// where it put obid, its plug-ins and web app), so the app's obid takes its own signed copies
    /// (Contents/Resources/obid); nil when nothing points there.
    static func withoutScriptFolders(_ config: [String: Any], prefix: String) -> [String: Any]? {
        let root = URL(filePath: prefix).standardizedFileURL.path
        var kept = config
        for key in ["bundledPlugins", "web"] {
            guard let path = config[key] as? String else { continue }
            let standard = URL(filePath: path).standardizedFileURL.path
            if standard == root || standard.hasPrefix(root + "/") { kept.removeValue(forKey: key) }
        }
        return kept.count == config.count ? nil : kept
    }

    /// Drops install.sh's plug-in and web folders from the configuration the app's obid reads,
    /// keeping everything else; install.sh's obid is `program`, `<prefix>/bin/obid`.
    private func dropScriptFolders(program: String) {
        let prefix = URL(filePath: program).deletingLastPathComponent().deletingLastPathComponent().path
        let file = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/Oby/obid/config.json")
        guard let data = try? Data(contentsOf: file),
              let config = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let kept = Self.withoutScriptFolders(config, prefix: prefix) else { return }
        do {
            let text = try JSONSerialization.data(withJSONObject: kept, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            try Self.writePrivately(text, to: file)
        } catch {
            Logger.feed.error("couldn't take install.sh's folders out of obid's configuration: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Writes `data` to `file` as a new file made 0600 from the start (never readable by others
    /// for a moment), then moved into place.
    static func writePrivately(_ data: Data, to file: URL) throws {
        let temporary = file.deletingLastPathComponent().appending(path: ".\(file.lastPathComponent).\(UUID().uuidString)")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
            guard rename(temporary.path, file.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        } catch {
            unlink(temporary.path)
            throw error
        }
    }

    func refresh() {
        status = service.status
        byScript = FileManager.default.fileExists(atPath: scriptAgent.path)
    }

    var isOn: Bool { status == .enabled }
    var needsApproval: Bool { status == .requiresApproval }

    /// Settings › Runner's word for it.
    var line: String {
        if byScript { return "Installed with install.sh" }
        return switch status {
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
