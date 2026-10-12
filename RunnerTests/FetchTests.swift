import Foundation
import Testing
@testable import ObyEngine

/// Jobs a merge releases fetch dev into one clone at the same moment: one at a time, and a fetch
/// that loses a ref race runs again, so none of them fails before it starts (#235).
struct FetchTests {
    static let job = Job(id: "f1", request: "fix oby #235", agent: "claude", account: "default", repo: "deskree-inc/oby",
                         branch: "oby/fix-235", base: "dev", pr: nil, kind: .fix, task: "Fix oby #235")

    /// What the tests stand in for git with: every fetch it was asked for, and how many ran at once.
    final class Git: @unchecked Sendable {
        private let lock = NSLock()
        private var running = 0
        private(set) var most = 0
        private(set) var fetches = 0
        /// What each fetch says, in turn; past the end, it succeeds.
        var failures: [String] = []

        func fetch() async -> Shell.Output {
            let err: String? = lock.withLock {
                running += 1
                most = max(most, running)
                fetches += 1
                return fetches <= failures.count ? failures[fetches - 1] : nil
            }
            try? await Task.sleep(for: .milliseconds(20))
            lock.withLock { running -= 1 }
            return Shell.Output(status: err == nil ? 0 : 1, out: Data(), err: err ?? "")
        }

        var stand: Shell.Stand {
            Shell.Stand { [self] arguments, _ in
                if arguments.contains("--git-common-dir") { return Shell.Output(status: 0, out: Data("/tmp/oby-clone/.git".utf8), err: "") }
                return await fetch()
            }
        }
    }

    /// Ten jobs' worktrees of one clone fetch dev at once: all succeed, and dev is where it is upstream.
    @Test func tenConcurrentFetchesIntoOneCloneAllSucceed() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appending(path: "source"), clone = folder.appending(path: "clone")
        let identity = ["-c", "user.name=Oby", "-c", "user.email=oby@example.com", "-c", "commit.gpgsign=false"]
        _ = try await Shell.ok(["git", "init", "--quiet", "-b", "dev", source.path])
        _ = try await Shell.ok(["git", "-C", source.path] + identity + ["commit", "--quiet", "--allow-empty", "-m", "one"])
        _ = try await Shell.ok(["git", "clone", "--quiet", source.path, clone.path])
        _ = try await Shell.ok(["git", "-C", source.path] + identity + ["commit", "--quiet", "--allow-empty", "-m", "two"])
        let head = try await Shell.ok(["git", "-C", source.path, "rev-parse", "HEAD"])
        var worktrees: [URL] = []
        for n in 0..<10 {
            let worktree = folder.appending(path: "jobs/\(n)")
            _ = try await Shell.ok(["git", "-C", clone.path, "worktree", "add", "--quiet", "--detach", worktree.path])
            worktrees.append(worktree)
        }

        let failed = await withTaskGroup(of: String?.self) { group in
            for worktree in worktrees {
                group.addTask {
                    do { try await Publish.fetch("dev", of: Self.job, into: worktree, from: source.path); return nil } catch { return error.localizedDescription }
                }
            }
            return await group.reduce(into: [String]()) { if let error = $1 { $0.append(error) } }
        }
        #expect(failed.isEmpty)
        #expect(try await Shell.ok(["git", "-C", clone.path, "rev-parse", "refs/remotes/origin/dev"]) == head)
    }

    /// However many ask at once, one fetch runs in a clone at a time.
    @Test func fetchesIntoOneCloneRunOneAtATime() async throws {
        let git = Git()
        try await Shell.$stand.withValue(git.stand) {
            try await withThrowingTaskGroup(of: Void.self) { group in
                for n in 0..<10 {
                    group.addTask { try await Publish.fetch("dev", of: Self.job, into: URL(filePath: "/tmp/oby-jobs/\(n)")) }
                }
                try await group.waitForAll()
            }
        }
        #expect(git.fetches == 10 && git.most == 1)
    }

    /// A fetch that lost a ref race to another one runs again, and succeeds.
    @Test func aFetchThatLostARefRaceSucceedsOnRetry() async throws {
        let git = Git()
        git.failures = ["error: fetching ref refs/remotes/origin/dev failed: incorrect old value provided"]
        try await Shell.$stand.withValue(git.stand) {
            try await Publish.fetch("dev", of: Self.job, into: URL(filePath: "/tmp/oby-jobs/f1"))
        }
        #expect(git.fetches == 2)
    }

    /// An Apple check fetching the base on the Mac takes its turn with the jobs' fetches into that
    /// clone, and runs again when it lost a ref race.
    @Test func anAppleChecksFetchTakesItsTurnAndRetriesARefRace() async throws {
        var check = MacCheck(id: "ab12cd34", job: "j", repo: "deskree-inc/oby", pr: 0, branch: "oby/build-118", base: "dev",
                             head: String(repeating: "a", count: 40), round: 1)
        check.kind = .apple
        let raced = Git()
        raced.failures = ["error: cannot lock ref 'refs/remotes/origin/dev': is at 1a2b but expected 3c4d"]
        try await Shell.$stand.withValue(raced.stand) {
            try await AppleCheck.fetch(check, bundle: Data(), into: URL(filePath: "/tmp/oby-clone"))
        }
        #expect(raced.fetches == 2)

        let git = Git()
        try await Shell.$stand.withValue(git.stand) {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { try await AppleCheck.fetch(check, bundle: Data(), into: URL(filePath: "/tmp/oby-clone")) }
                for n in 0..<3 {
                    group.addTask { try await Publish.fetch("dev", of: Self.job, into: URL(filePath: "/tmp/oby-jobs/\(n)")) }
                }
                try await group.waitForAll()
            }
        }
        #expect(git.fetches == 4 && git.most == 1)
    }

    /// Any other failure isn't a race: it fails at once, saying why.
    @Test func anotherFailureIsNotRetried() async throws {
        let git = Git()
        git.failures = ["fatal: couldn't find remote ref refs/heads/dev"]
        let error = await #expect(throws: Shell.Failure.self) {
            try await Shell.$stand.withValue(git.stand) {
                try await Publish.fetch("dev", of: Self.job, into: URL(filePath: "/tmp/oby-jobs/f1"))
            }
        }
        #expect(error?.message == "Couldn't fetch dev: fatal: couldn't find remote ref refs/heads/dev")
        #expect(git.fetches == 1)
    }

    @Test func refRacesAreTheOnesGitNames() {
        #expect(Publish.lostRace("error: cannot lock ref 'refs/remotes/origin/dev': is at 1a2b but expected 3c4d"))
        #expect(Publish.lostRace(" ! 1a2b..3c4d  dev -> origin/dev  (unable to update local ref)"))
        #expect(!Publish.lostRace("fatal: could not read Username for 'https://github.com'"))
    }
}
