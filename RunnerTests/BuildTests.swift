import Foundation
import Testing
@testable import ObyEngine

struct BuildTests {
    @Test func agentsYieldAndCapSwiftBuilds() {
        #expect(Agents.niced(["swift", "build"]) == ["nice", "-n", "10", "swift", "build"])
        #expect(Agents.buildEnvironment(processorCount: 16)["OBY_SWIFT_BUILD_JOBS"] == "8")
        #expect(Agents.buildEnvironment(processorCount: 1)["OBY_SWIFT_BUILD_JOBS"] == "1")
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

    @Test func seedingUsesOnlyMatchingAuthorAndWarmCommits() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let author = folder.appending(path: "jobs/author")
        let destination = folder.appending(path: "jobs/review")
        try FileManager.default.createDirectory(at: author, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        _ = try await Shell.ok(["git", "init", "--quiet", author.path])
        _ = try await Shell.ok(["git", "-C", author.path, "config", "user.email", "test@example.com"])
        _ = try await Shell.ok(["git", "-C", author.path, "config", "user.name", "Test"])
        try Data("source".utf8).write(to: author.appending(path: "source"))
        _ = try await Shell.ok(["git", "-C", author.path, "add", "source"])
        _ = try await Shell.ok(["git", "-C", author.path, "commit", "--quiet", "-m", "source"])
        let commit = try await Shell.ok(["git", "-C", author.path, "rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
        try FileManager.default.createDirectory(at: author.appending(path: ".build"), withIntermediateDirectories: true)
        try Data("author cache".utf8).write(to: author.appending(path: ".build/state"))
        var review = Job(id: "review", request: "", agent: "claude", account: "default", repo: "deskree-inc/oby",
                         branch: "oby/review", base: "dev", kind: .review, task: "Review")
        review.reviewOf = "author"

        #expect(try await Workspace.seedBuild(review, commit: commit, into: destination, root: folder))
        #expect(try String(contentsOf: destination.appending(path: ".build/state"), encoding: .utf8) == "author cache")
        try FileManager.default.removeItem(at: destination.appending(path: ".build"))
        #expect(!(try await Workspace.seedBuild(review, commit: "wrong", into: destination, root: folder)))

        let updates = folder.appending(path: "updates/source/.build")
        try FileManager.default.createDirectory(at: updates, withIntermediateDirectories: true)
        try Data("warm cache".utf8).write(to: updates.appending(path: "state"))
        try Data("\(commit)\n".utf8).write(to: folder.appending(path: "updates/cache-commit"))
        var build = review
        build.reviewOf = nil
        #expect(try await Workspace.seedBuild(build, commit: commit, into: destination, root: folder))
        #expect(try String(contentsOf: destination.appending(path: ".build/state"), encoding: .utf8) == "warm cache")
    }

    @Test func swiftWrapperCapsAndTimesAPlainTest() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let tools = folder.appending(path: "tools")
        let worktree = folder.appending(path: "worktree")
        try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        let log = folder.appending(path: "swift-args")
        try "#!/bin/sh\nprintf '%s\\n' \"$@\" >> \"\(log.path)\"\n".write(to: tools.appending(path: "swift"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: tools.appending(path: "swift").path)
        try Agents.installSwiftWrapper(in: worktree)
        let path = "\(tools.path):/usr/bin:/bin"
        var env = Agents.swiftEnvironment(worktree: worktree, base: ["PATH": path])
        env.merge(Agents.buildEnvironment(processorCount: 8)) { $1 }
        let result = try await Shell.run(["swift", "test", "--package-path", "Sub", "--scratch-path", ".cache", "--configuration", "release"], in: worktree, env: env, timeout: 5)
        #expect(result.status == 0)
        #expect(try String(contentsOf: log, encoding: .utf8).contains("build\n-j\n4\n--package-path\nSub\n--scratch-path\n.cache\n--configuration\nrelease\ntest\n--package-path\nSub\n--scratch-path\n.cache\n--configuration\nrelease\n-j\n4"))
        #expect(Int(try String(contentsOf: worktree.appending(path: ".oby/first-swift-build-seconds"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)) != nil)
    }

    @Test func checksRunAtTheRunnerPriority() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let expected = try await Shell.ok(Agents.niced(["sh", "-c", "ps -o ni= -p $$"]), in: folder)
        let result = await Rounds.run("ps -o ni= -p $$", in: folder, timeout: 5, env: [:], boxed: false)
        #expect(result.passed)
        #expect(result.output.trimmingCharacters(in: .whitespacesAndNewlines) == expected.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
