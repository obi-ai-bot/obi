import Foundation
import Testing
@testable import Oby

/// The runner ships inside Oby.app as a login item (#283): the build bundles its launchd plist at
/// Contents/Library/LaunchAgents and the executable at Contents/Helpers ("Bundle the runner").
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
