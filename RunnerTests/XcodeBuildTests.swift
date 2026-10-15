import Foundation
import Testing
@testable import ObyEngine

@Suite struct XcodeBuildTests {
    @Test func buildTagsUseUTCDateAndSequence() {
        let date = Date(timeIntervalSince1970: 1_792_000_000)
        #expect(XcodeBuild.tagName(at: date, sequence: 3) == "oby-build/2026-10-14.3")
    }

    @Test func onlyAppleFacingFilesRequestACloudBuild() {
        for path in ["apps/ios/app/Chat.swift", "apps/ios/tests/ChatTests.swift", "apps/shared/Runner.swift", "apps/watch/HomeView.swift",
                     "apps/ios/live-activity/ObyActivity.swift", "character/character.json", "apps/icon/compose.swift", "apps/Oby.xcodeproj/project.pbxproj"] {
            #expect(XcodeBuild.includes(path))
        }
        for path in ["Engine/Desk.swift", "Runner/API.swift", "docs/runner-api.md", "apps/mac/app/App.swift"] {
            #expect(!XcodeBuild.includes(path))
        }
    }

    @Test @MainActor func anObyMergeSettlesItsBatchIncludingTerminalJobsWithoutPullRequests() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = JobStore(url: folder.appending(path: "oby.sqlite"))
        let repo = "deskree-inc/oby"
        let head = String(repeating: "a", count: 40)
        let url = "https://github.com/deskree-inc/oby/pull/80"

        var author = Job(id: "author", request: "", agent: "claude", account: "default", repo: repo,
                         branch: "oby/build-341", base: "dev", kind: .fix, task: "Build the feature")
        author.status = .done
        author.batch = "chat-turn"
        author.commits = 1
        author.published = url
        author.outgoing = [Outgoing(action: .push, repo: repo, id: head, branch: author.branch)]
        author.review = Review(verdict: .approved, job: "review", agent: "codex", account: "reviewer", round: 1)
        author.macCheck = MacCheck(id: "check", job: author.id, repo: repo, pr: 80, branch: author.branch,
                                   base: "dev", head: head, round: 1)
        author.macCheck?.state = .passed
        store.save(author)

        for (id, status) in [("failed", Job.Status.failed), ("interrupted", .interrupted), ("answer", .done)] {
            var member = Job(id: id, request: "", agent: "claude", account: "default", repo: repo,
                             branch: "oby/\(id)", base: "dev", kind: .fix, task: "A batch member")
            member.batch = "chat-turn"
            member.status = status
            store.save(member)
        }

        let desk = Desk(accounts: AccountStore(root: folder), store: store)
        desk.xcodeBuildInterval = .milliseconds(10)
        desk.scanForMerge = { _, _ in [] }
        desk.mergePullRequest = { _, _ in }
        var candidates = 0
        var tags: [(String, String, String)] = []
        desk.xcodeBuildCandidate = { _ in
            candidates += 1
            return ("oby-build/2026-10-13.1", head, nil)
        }
        desk.createXcodeBuildTag = { repo, tag, head in tags.append((repo, tag, head)) }

        await desk.mergeChecked(author.id)
        for _ in 0..<100 where desk.job(author.id)?.build == nil { try await Task.sleep(for: .milliseconds(10)) }

        #expect(desk.job(author.id)?.pullRequest?.state == .merged)
        #expect(candidates == 1)
        #expect(tags.map { "\($0.0) \($0.1) \($0.2)" } == ["\(repo) oby-build/2026-10-13.1 \(head)"])
        #expect(desk.job("failed")?.build != nil && desk.job("interrupted")?.build != nil && desk.job("answer")?.build != nil)
    }

    @Test @MainActor func batchesSettlingWithinTheCoalescingWindowShareOneTag() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = JobStore(url: folder.appending(path: "oby.sqlite"))
        for (id, batch) in [("first", "chat-one"), ("second", "chat-two")] {
            var job = Job(id: id, request: "", agent: "claude", account: "default", repo: "deskree-inc/oby",
                          branch: "oby/\(id)", base: "dev", kind: .fix, task: "A merged batch")
            job.status = .done
            job.batch = batch
            job.pullRequest = PullRequestStatus(state: .merged, base: "dev", checkedAt: .now)
            store.save(job)
        }

        let desk = Desk(accounts: AccountStore(root: folder), store: store)
        desk.xcodeBuildInterval = .milliseconds(100)
        var candidates = 0
        var tags = 0
        desk.xcodeBuildCandidate = { _ in
            candidates += 1
            return ("oby-build/2026-10-13.1", String(repeating: "a", count: 40), nil)
        }
        desk.createXcodeBuildTag = { _, _, _ in tags += 1 }

        await desk.settleBuildBatch("first")
        try await Task.sleep(for: .milliseconds(20))
        await desk.settleBuildBatch("second")
        for _ in 0..<100 where tags == 0 { try await Task.sleep(for: .milliseconds(10)) }

        #expect(candidates == 1)
        #expect(tags == 1)
        #expect(desk.job("first")?.build != nil && desk.job("second")?.build != nil)
    }

    @Test @MainActor func aBatchWithARunningJobIsNotTaggedWhenAnotherBatchEndsTheWindow() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = JobStore(url: folder.appending(path: "oby.sqlite"))
        for (id, batch, state) in [("merged", "chat-one", PullRequestStatus.State.merged), ("open", "chat-two", .open),
                                   ("alone", "chat-two", .merged)] {
            var job = Job(id: id, request: "", agent: "claude", account: "default", repo: "deskree-inc/oby",
                          branch: "oby/\(id)", base: "dev", kind: .fix, task: "A batch member")
            job.status = .done
            job.batch = batch
            job.published = "https://github.com/deskree-inc/oby/pull/\(id.count)"
            job.pullRequest = PullRequestStatus(state: state, base: "dev", checkedAt: .now)
            store.save(job)
        }

        let desk = Desk(accounts: AccountStore(root: folder), store: store)
        desk.xcodeBuildInterval = .milliseconds(10)
        var tags = 0
        desk.xcodeBuildCandidate = { _ in ("oby-build/2026-10-13.1", String(repeating: "a", count: 40), nil) }
        desk.createXcodeBuildTag = { _, _, _ in tags += 1 }

        await desk.settleBuildBatch("merged")
        await desk.settleBuildBatch("alone")
        for _ in 0..<100 where tags == 0 { try await Task.sleep(for: .milliseconds(10)) }
        try await Task.sleep(for: .milliseconds(50))

        #expect(tags == 1)
        #expect(desk.job("merged")?.build != nil)
        #expect(desk.job("alone")?.build == nil && desk.job("open")?.build == nil)
    }

    @Test @MainActor func aRestartInsideTheWindowStillTagsTheSettledBatches() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = JobStore(url: folder.appending(path: "oby.sqlite"))
        for id in ["first", "second"] {
            var job = Job(id: id, request: "", agent: "claude", account: "default", repo: "deskree-inc/oby",
                          branch: "oby/\(id)", base: "dev", kind: .fix, task: "A merged batch")
            job.status = .done
            job.batch = "chat-one"
            job.pullRequest = PullRequestStatus(state: .merged, base: "dev", checkedAt: .now)
            store.save(job)
        }

        let before = Desk(accounts: AccountStore(root: folder), store: store)
        before.xcodeBuildInterval = .seconds(3600)
        before.xcodeBuildCandidate = { _ in
            Issue.record("settled before the window ended")
            return (nil, "", nil)
        }
        before.createXcodeBuildTag = { _, _, _ in Issue.record("tagged before the window ended") }
        await before.settleBuildBatch("second")
        before.pendingXcodeBuildTask?.cancel()
        #expect(store.job("first")?.buildSettled != nil && store.job("second")?.buildSettled != nil)

        // The runner restarts: a new desk reads the same store, and the window's start was kept.
        let after = Desk(accounts: AccountStore(root: folder), store: store)
        after.xcodeBuildInterval = .milliseconds(10)
        var tags: [String] = []
        after.xcodeBuildCandidate = { _ in ("oby-build/2026-10-13.1", String(repeating: "a", count: 40), nil) }
        after.createXcodeBuildTag = { _, tag, _ in tags.append(tag) }
        after.resumeXcodeBuilds()
        for _ in 0..<100 where tags.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        try await Task.sleep(for: .milliseconds(50))

        #expect(tags == ["oby-build/2026-10-13.1"])
        #expect(after.job("first")?.build != nil && after.job("second")?.build != nil)
    }
}
