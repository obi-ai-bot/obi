import Foundation
import Testing
@testable import ObyEngine

struct BuildTests {
    @Test func agentsYieldAndCapSwiftBuilds() {
        #expect(Agents.niced(["swift", "build"]) == ["nice", "-n", "10", "swift", "build"])
        #expect(Agents.buildEnvironment(processorCount: 16)["SWIFTPM_BUILD_JOBS"] == "8")
        #expect(Agents.buildEnvironment(processorCount: 1)["SWIFTPM_BUILD_JOBS"] == "1")
    }

    @Test func aFakeWorktreeGetsTheWarmBuild() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let cached = folder.appending(path: ".build")
        let worktree = folder.appending(path: "worktree")
        try FileManager.default.createDirectory(at: cached, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        try Data("cached object".utf8).write(to: cached.appending(path: "state"))

        #expect(try await Workspace.copyBuild(cached, to: worktree.appending(path: ".build")))
        #expect(try String(contentsOf: worktree.appending(path: ".build/state"), encoding: .utf8) == "cached object")
    }
}
