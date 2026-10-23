import Foundation
import ServiceManagement
import Testing
@testable import Oby

/// obid ships inside Oby.app as a login item (the owner's decision of 2026-10-18): the build bundles
/// its launchd plist at Contents/Library/LaunchAgents, the executable at Contents/Helpers and its
/// plug-ins at Contents/Resources/obid ("Bundle obid").
struct LoginItemTests {
    /// The tests run hosted by Oby.app itself, so `Bundle.main` is the app bundle the build made.
    @Test func theAppBundlesThePlistAndTheRunner() throws {
        #expect(RunnerLoginItem.missing(in: .main) == [])
        let data = try Data(contentsOf: Bundle.main.bundleURL.appending(path: RunnerLoginItem.plistPath))
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        #expect(plist?["Label"] as? String == RunnerLoginItem.label)
        #expect(plist?["BundleProgram"] as? String == RunnerLoginItem.helperPath)
        #expect(plist?["AssociatedBundleIdentifiers"] as? [String] == ["com.deskree.oby"])
        #expect(RunnerLoginItem.plistPath.hasSuffix("/" + RunnerLoginItem.plist))
        #expect(plist?["ProgramArguments"] as? [String] == ["obid", "serve"])
        #expect(RunnerLoginItem.label == "com.deskree.oby.obid" && RunnerLoginItem.helperPath == "Contents/Helpers/obid")
        // Never install.sh's label: macOS would tie the app's agent to that file and never start it.
        #expect(RunnerLoginItem.label != RunnerLoginItem.scriptLabel)
        // The Swift runner's plist stays, only so an older registration can be undone.
        let swift = Bundle.main.bundleURL.appending(path: "Contents/Library/LaunchAgents/\(RunnerLoginItem.swiftRunnerPlist)")
        #expect(FileManager.default.fileExists(atPath: swift.path))
        let plugins = Bundle.main.bundleURL.appending(path: "Contents/Resources/obid/plugins")
        #expect(FileManager.default.fileExists(atPath: plugins.path))
    }

    /// install.sh's obid moves only when it uses the file the app's obid reads.
    @Test func installShsObidMovesOnlyWithTheSameConfiguration() {
        let home = URL(filePath: "/Users/someone")
        let file = "/Users/someone/Library/Application Support/Oby/obid/config.json"
        #expect(RunnerLoginItem.cantMove(arguments: ["/x/bin/obid", "serve", "--config", file], home: home) == nil)
        #expect(RunnerLoginItem.cantMove(arguments: ["/x/bin/obid", "serve", "--config=\(file)"], home: home) == nil)
        #expect(RunnerLoginItem.cantMove(arguments: ["/x/bin/obid", "serve"], home: home) == nil)
        let elsewhere = RunnerLoginItem.cantMove(arguments: ["/x/bin/obid", "serve", "--config", "/srv/obid.json"], home: home)
        #expect(elsewhere?.contains("/srv/obid.json") == true)
    }

    /// The move goes on only when install.sh's obid is stopped or wasn't running.
    @Test func theMoveGoesOnOnlyOnceInstallShsObidStopped() {
        for status: Int32 in [0, 3, 113] { #expect(RunnerLoginItem.bootout(status) == .stopped) }
        // EINPROGRESS: still stopping, so the move waits for launchd to let it go.
        #expect(RunnerLoginItem.bootout(36) == .stopping)
        for status: Int32 in [1, 5, 37, 125] { #expect(RunnerLoginItem.bootout(status) == .failed) }
        #expect(!RunnerLoginItem.loaded("com.deskree.oby.nothing.\(UUID().uuidString)"))
    }

    /// The configuration is written 0600 from the start and replaces the file whole.
    @Test func theConfigurationIsWrittenPrivately() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "oby-config-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "config.json")
        try Data("old".utf8).write(to: file)
        try RunnerLoginItem.writePrivately(Data("{}".utf8), to: file)
        #expect(try String(contentsOf: file, encoding: .utf8) == "{}")
        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["config.json"])
    }

    /// After the move, the configuration no longer points at install.sh's own plug-ins and web app,
    /// so the app's obid takes its signed copies; other paths and keys stay.
    @Test func theMoveDropsOnlyInstallShsFolders() throws {
        let prefix = "/Users/someone/Library/Application Support/Oby/obid"
        let config: [String: Any] = ["home": "/Users/someone/Library/Application Support/Oby/Runner",
                                     "bundledPlugins": prefix + "/share/plugins", "web": prefix + "/share/web",
                                     "listen": "127.0.0.1:7777"]
        let kept = try #require(RunnerLoginItem.withoutScriptFolders(config, prefix: prefix))
        #expect(kept["bundledPlugins"] == nil && kept["web"] == nil)
        #expect(kept["home"] as? String == "/Users/someone/Library/Application Support/Oby/Runner")
        #expect(kept["listen"] as? String == "127.0.0.1:7777")
        let elsewhere: [String: Any] = ["bundledPlugins": "/srv/plugins", "web": prefix + "-other/web"]
        #expect(RunnerLoginItem.withoutScriptFolders(elsewhere, prefix: prefix) == nil)
    }

    /// With no install.sh agent where it looks, nothing runs instead of the app's obid.
    @Test func noScriptAgentMeansTheAppsObid() {
        let item = RunnerLoginItem(service: .agent(plistName: "com.deskree.oby.nothing.plist"),
                                   swiftRunner: .agent(plistName: "com.deskree.oby.nothing-else.plist"),
                                   scriptAgent: URL(filePath: "/nonexistent/com.deskree.obid.plist"))
        #expect(!item.byScript)
        #expect(item.line != "Installed with install.sh")
    }

    /// Its status is read from launchd, never guessed: a fresh item of another name isn't registered.
    @Test func anUnknownItemIsNotFound() {
        let item = RunnerLoginItem(service: .agent(plistName: "com.deskree.oby.nothing.plist"))
        #expect(!item.isOn)
        #expect(item.status == .notFound || item.status == .notRegistered)
    }

    /// At launch: registered when nothing is, registered again while obid doesn't run whatever
    /// macOS says of a stale registration (#790; the 0.2.0 install of 2026-10-20, Apple Development
    /// to Developer ID), else left alone, and never from a copy that may not register.
    @Test func atLaunchRegistersAgainOnlyWhenStale() {
        func decide(_ status: SMAppService.Status, signingChanged: Bool = false, runs: Bool = true,
                    onThisMac: Bool = true, byScript: Bool = false, mayRegister: Bool = true) -> RunnerLoginItem.AtLaunch {
            RunnerLoginItem.atLaunch(onThisMac: onThisMac, byScript: byScript, mayRegister: mayRegister, status: status,
                                     signingChanged: signingChanged, runs: runs)
        }
        func reregisters(_ decision: RunnerLoginItem.AtLaunch) -> Bool {
            if case .reregister = decision { true } else { false }
        }
        #expect(decide(.notRegistered) == .register)
        #expect(decide(.notRegistered, signingChanged: true, runs: false) == .register)
        #expect(decide(.enabled) == .nothing)
        #expect(reregisters(decide(.enabled, runs: false)))
        // The launch-constraint refusal: a new kind of certificate, and obid down.
        #expect(reregisters(decide(.enabled, signingChanged: true, runs: false)))
        // Debug and the installed app take turns: a working obid stays up.
        #expect(decide(.enabled, signingChanged: true) == .nothing)
        // A registration macOS lost track of, while launchd still refuses obid, is registered again.
        #expect(reregisters(decide(.notFound, runs: false)))
        #expect(decide(.notFound) == .nothing)
        // Approval stays the user's step.
        #expect(decide(.requiresApproval, signingChanged: true, runs: false) == .nothing)
        // A remote runner, or install.sh's obid, serves this Mac instead.
        #expect(decide(.enabled, signingChanged: true, runs: false, onThisMac: false) == .nothing)
        #expect(decide(.notRegistered, byScript: true) == .nothing)
        // A translocated or not-installed copy never takes the registration.
        #expect(decide(.notRegistered, mayRegister: false) == .nothing)
        #expect(decide(.enabled, runs: false, mayRegister: false) == .nothing)
        #expect(decide(.notFound, signingChanged: true, runs: false, mayRegister: false) == .nothing)
        #expect(RunnerLoginItem.launchd("com.deskree.oby.nothing.\(UUID().uuidString)") == nil)
    }

    /// After an update, an obid still running the old executable is restarted, once (2026-10-23,
    /// the MacBook Air on 0.3.0 with 0.2.1's obid: "There's no such endpoint").
    @Test func anObidFromBeforeTheUpdateIsRestarted() throws {
        func decide(_ status: SMAppService.Status, runs: Bool = true, outdated: Bool, onThisMac: Bool = true) -> RunnerLoginItem.AtLaunch {
            RunnerLoginItem.atLaunch(onThisMac: onThisMac, byScript: false, mayRegister: true, status: status,
                                     signingChanged: false, runs: runs, outdated: outdated)
        }
        #expect(decide(.enabled, outdated: true) == .restart)
        #expect(decide(.enabled, outdated: false) == .nothing)
        // Not running at all is a re-register, and a remote runner is left alone.
        if case .reregister = decide(.enabled, runs: false, outdated: true) {} else { Issue.record("expected a re-register") }
        #expect(decide(.enabled, outdated: true, onThisMac: false) == .nothing)
        let now = Date()
        #expect(RunnerLoginItem.stale(started: now.addingTimeInterval(-3600), replaced: now))
        #expect(!RunnerLoginItem.stale(started: now, replaced: now.addingTimeInterval(-3600)))
        #expect(!RunnerLoginItem.stale(started: now, replaced: now), "the same moment is not stale")
        // Read from launchctl's own words: this test process, started before a file written now, is outdated.
        let file = FileManager.default.temporaryDirectory.appending(path: "obid-\(UUID().uuidString)")
        try Data().write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let pid = ProcessInfo.processInfo.processIdentifier
        let printed = "gui/501/com.deskree.oby.obid = {\n\tstate = running\n\tprogram = \(file.path)\n\tpid = \(pid)\n}"
        if try #require(RunnerLoginItem.started(pid)) < Date().addingTimeInterval(-1.5) {
            #expect(RunnerLoginItem.outdated(printed))
        }
        #expect(!RunnerLoginItem.outdated(printed.replacingOccurrences(of: "pid = \(pid)", with: "")), "no pid, no restart")
        #expect(!RunnerLoginItem.outdated(nil))
    }

    /// A team or kind of certificate is recorded at every launch; only a change from one on record counts.
    @Test func signingChangesAreRecorded() throws {
        let suite = "oby-login-item-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = RunnerLoginItem.kindKey
        #expect(!RunnerLoginItem.changed("Apple Development", key: key, in: defaults))
        #expect(!RunnerLoginItem.changed("Apple Development", key: key, in: defaults))
        #expect(RunnerLoginItem.changed("Developer ID Application", key: key, in: defaults))
        // Ad hoc says nothing, and keeps what's on record.
        #expect(!RunnerLoginItem.changed(nil, key: key, in: defaults))
        #expect(!RunnerLoginItem.changed("Developer ID Application", key: key, in: defaults))
        #expect(RunnerLoginItem.kind(of: "Developer ID Application: Deskree Technologies Inc. (3UV9W5SV7W)") == "Developer ID Application")
        #expect(RunnerLoginItem.kind(of: "Apple Development: Someone (47H6K3VA5H)") == "Apple Development")
        #expect(RunnerLoginItem.kind(of: "ad hoc") == nil)
    }

    /// The installed app registers obid only from Applications; a Debug build from anywhere but a
    /// translocated copy or a mounted disk image.
    @Test func onlyAnInstalledCopyRegisters() {
        let home = "/Users/someone"
        func may(_ path: String, debug: Bool = false) -> Bool { RunnerLoginItem.mayRegister(path, home: home, debug: debug) }
        #expect(may("/Applications/Oby.app"))
        #expect(may("/Users/someone/Applications/Oby.app"))
        let translocated = "/private/var/folders/x1/abc/T/AppTranslocation/3F2A-11/d/Oby.app"
        for path in [translocated, "/Volumes/Oby/Oby.app", "/Users/someone/Downloads/Oby.app",
                     "/Users/other/Applications/Oby.app", "/Applications/../Users/someone/Downloads/Oby.app"] {
            #expect(!may(path), "\(path)")
        }
        #expect(may("/Users/someone/Library/Developer/Xcode/DerivedData/Oby/Build/Products/Debug/Oby.app", debug: true))
        #expect(!may(translocated, debug: true))
        #expect(!may("/Volumes/Oby/Oby.app", debug: true))
        // The test host is a Debug build in DerivedData.
        #expect(RunnerLoginItem.mayRegister())
    }

    /// What's missing is named, so a build that forgot the phase says so.
    @Test func namesWhatAnEmptyBundleLacks() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "oby-bundle-\(UUID().uuidString).app")
        try FileManager.default.createDirectory(at: folder.appending(path: "Contents"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let bundle = try #require(Bundle(url: folder))
        #expect(RunnerLoginItem.missing(in: bundle) == [RunnerLoginItem.plistPath, RunnerLoginItem.helperPath])
    }
}
