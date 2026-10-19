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
        for status: Int32 in [0, 3, 36, 113] { #expect(RunnerLoginItem.stopped(bootout: status)) }
        for status: Int32 in [1, 5, 37, 125] { #expect(!RunnerLoginItem.stopped(bootout: status)) }
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

    /// What's missing is named, so a build that forgot the phase says so.
    @Test func namesWhatAnEmptyBundleLacks() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "oby-bundle-\(UUID().uuidString).app")
        try FileManager.default.createDirectory(at: folder.appending(path: "Contents"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let bundle = try #require(Bundle(url: folder))
        #expect(RunnerLoginItem.missing(in: bundle) == [RunnerLoginItem.plistPath, RunnerLoginItem.helperPath])
    }
}
