import Foundation
import Testing
@testable import Oby

/// `oby-mcp` ships inside Oby.app at Contents/Helpers (#385), next to the runner.
struct MCPHelperTests {
    /// The tests run hosted by Oby.app itself, so `Bundle.main` is the app bundle the build made.
    @Test func theAppBundlesObyMCP() {
        #expect(MCPHelper.missing(in: .main) == [])
        #expect(MCPHelper.isPresent)
        #expect(FileManager.default.fileExists(atPath: Bundle.main.bundleURL.appending(path: MCPHelper.commitPath).path))
    }

    @Test func namesWhatAnEmptyBundleLacks() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "oby-mcp-bundle-\(UUID().uuidString).app")
        try FileManager.default.createDirectory(at: folder.appending(path: "Contents"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let bundle = try #require(Bundle(url: folder))
        #expect(MCPHelper.missing(in: bundle) == [MCPHelper.helperPath])
    }

    @Test func addCommandsPointAtTheBundledPath() {
        let path = "/Applications/Oby.app/Contents/Helpers/oby-mcp"
        #expect(MCPHelper.claudeAdd(path: path) == ["claude", "mcp", "add", "--scope", "user", "oby", "--", path])
        #expect(MCPHelper.codexAdd(path: path) == ["codex", "mcp", "add", "oby", "--", path])
        #expect(MCPHelper.shellLine(MCPHelper.claudeAdd(path: path)).contains(path))
    }
}
