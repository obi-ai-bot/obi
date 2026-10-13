import Foundation
import Testing
@testable import ObyEngine

@Suite struct XcodeBuildTests {
    @Test func buildTagsUseUTCDateAndSequence() {
        let date = Date(timeIntervalSince1970: 1_792_000_000)
        #expect(XcodeBuild.tagName(at: date, sequence: 3) == "oby-build/2026-10-14.3")
    }

    @Test func onlyAppleFacingFilesRequestACloudBuild() {
        for path in ["iOS/Chat.swift", "iOSTests/ChatTests.swift", "Shared/Runner.swift", "Watch/HomeView.swift",
                     "LiveActivity/ObyActivity.swift", "Character/character.json", "Icon/compose.swift", "Oby.xcodeproj/project.pbxproj"] {
            #expect(XcodeBuild.includes(path))
        }
        for path in ["Engine/Desk.swift", "Runner/API.swift", "docs/runner-api.md", "Mac/App.swift"] {
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
}
