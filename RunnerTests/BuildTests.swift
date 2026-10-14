import Foundation
import Testing
@testable import ObyEngine

struct BuildTests {
    @Test func agentsYieldAndCapSwiftBuilds() {
        let adjustment = max(0, Agents.processPriority - Agents.currentPriority)
        #expect(Agents.niced(["swift", "build"]) == ["nice", "-n", String(adjustment), "swift", "build"])
        #expect(Agents.nicedForCurrentProcess(["swift", "test"], inheritedPriority: 19) == ["nice", "-n", "0", "swift", "test"])
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
        let authorModuleCache = author.appending(path: ".build/out/ModuleCache.noindex/nested")
        try FileManager.default.createDirectory(at: authorModuleCache, withIntermediateDirectories: true)
        try Data("stale module".utf8).write(to: authorModuleCache.appending(path: "SwiftShims.pcm"))
        var review = Job(id: "review", request: "", agent: "claude", account: "default", repo: "deskree-inc/oby",
                         branch: "oby/review", base: "dev", kind: .review, task: "Review")
        review.reviewOf = "author"

        #expect(try await Workspace.seedBuild(review, commit: commit, into: destination, root: folder))
        #expect(try String(contentsOf: destination.appending(path: ".build/state"), encoding: .utf8) == "author cache")
        #expect(!FileManager.default.fileExists(atPath: destination.appending(path: ".build/out/ModuleCache.noindex").path))
        try FileManager.default.removeItem(at: destination.appending(path: ".build"))
        #expect(!(try await Workspace.seedBuild(review, commit: "wrong", into: destination, root: folder)))

        let updates = folder.appending(path: "updates/source/.build")
        try FileManager.default.createDirectory(at: updates, withIntermediateDirectories: true)
        try Data("warm cache".utf8).write(to: updates.appending(path: "state"))
        let warmModuleCache = updates.appending(path: "x86_64/ModuleCache.abc")
        try FileManager.default.createDirectory(at: warmModuleCache, withIntermediateDirectories: true)
        try Data("\(commit)\n".utf8).write(to: folder.appending(path: "updates/cache-commit"))
        var build = review
        build.reviewOf = nil
        #expect(try await Workspace.seedBuild(build, commit: commit, into: destination, root: folder))
        #expect(try String(contentsOf: destination.appending(path: ".build/state"), encoding: .utf8) == "warm cache")
        #expect(!FileManager.default.fileExists(atPath: destination.appending(path: ".build/x86_64/ModuleCache.abc").path))
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
        let result = try await Shell.run(["swift", "test", "--package-path", "Sub", "--scratch-path", ".cache", "--configuration", "release"], in: worktree, env: env, timeout: 30)
        #expect(result.status == 0)
        #expect(try String(contentsOf: log, encoding: .utf8).contains("build\n-j\n4\n--package-path\nSub\n--scratch-path\n.cache\n--configuration\nrelease\ntest\n--package-path\nSub\n--scratch-path\n.cache\n--configuration\nrelease\n-j\n4"))
        #expect(Int(try String(contentsOf: worktree.appending(path: ".oby/first-swift-build-seconds"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)) != nil)
    }

    @Test func reviewRetriesModuleCacheBuildFailureOnceFromCleanBuildDirectory() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let tools = folder.appending(path: "tools")
        let worktree = folder.appending(path: "worktree")
        let oby = worktree.appending(path: ".oby")
        try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: oby, withIntermediateDirectories: true)
        let count = folder.appending(path: "calls")
        let fakeSwift = tools.appending(path: "swift")
        let script = """
        #!/bin/sh
        count=0
        [ ! -f "\(count.path)" ] || count=$(cat "\(count.path)")
        count=$((count + 1))
        printf '%s\\n' "$count" > "\(count.path)"
        if [ "$count" -eq 1 ]; then
            echo "error: precompiled file was compiled with module cache path '/old/.build/ModuleCache.noindex'"
            exit 1
        fi
        echo "ran $*"
        """
        try script.write(to: fakeSwift, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fakeSwift.path)
        try Data().write(to: oby.appending(path: "review-job"))
        try FileManager.default.createDirectory(at: worktree.appending(path: ".build"), withIntermediateDirectories: true)
        try Data("stale object".utf8).write(to: worktree.appending(path: ".build/stale"))
        try Agents.installSwiftWrapper(in: worktree)
        let path = "\(tools.path):/usr/bin:/bin"
        var env = Agents.swiftEnvironment(worktree: worktree, base: ["PATH": path])
        env.merge(Agents.buildEnvironment(processorCount: 8)) { $1 }

        let result = try await Shell.run(["swift", "test"], in: worktree, env: env, timeout: 30)

        #expect(result.status == 0)
        #expect(FileManager.default.fileExists(atPath: worktree.appending(path: ".oby/first-swift-build-seconds.review-retried").path))
        #expect(!FileManager.default.fileExists(atPath: worktree.appending(path: ".build/stale").path))
        #expect(String(decoding: result.out, as: UTF8.self).contains("retrying once with a clean .build"))
        #expect(String(decoding: result.out, as: UTF8.self).contains("ran test"))
    }

    @Test func checksRunAtTheRunnerPriority() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let expected = try await Shell.ok(Agents.nicedForCurrentProcess(["sh", "-c", "ps -o ni= -p $$"]), in: folder)
        let result = await Rounds.run("ps -o ni= -p $$", in: folder, timeout: 5, env: [:], boxed: false)
        #expect(result.passed)
        #expect(result.output.trimmingCharacters(in: .whitespacesAndNewlines) == expected.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
