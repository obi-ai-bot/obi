import Foundation
import Testing
@testable import Oby

/// Archived and the task's menu (Sangam's ArchiveView.tsx, TaskMenu.tsx; apps/mac/app/App/TaskMenu.swift).
struct ArchiveTests {
    let now = Date(timeIntervalSince1970: 1_791_582_173)
    let day: TimeInterval = 86_400

    /// Done tasks leave Home after Archive completed's wait (3 days unless changed), at once when
    /// archived by hand or taken by an older Clear done; never while they're going or need you.
    @Test func whatLeavesHomeForArchived() {
        let after = ArchiveAfter.threeDays
        #expect(ArchiveAfter(rawValue: "3d") == .threeDays && ArchiveAfter.allCases.map(\.label) == ["After a day", "After 3 days", "After a week", "Never"])
        #expect(!after.archives(settled: true, finished: now - 2 * day, archived: nil, clearedAt: nil, now: now))
        #expect(after.archives(settled: true, finished: now - 4 * day, archived: nil, clearedAt: nil, now: now))
        #expect(ArchiveAfter.day.archives(settled: true, finished: now - 2 * day, archived: nil, clearedAt: nil, now: now))
        #expect(!ArchiveAfter.never.archives(settled: true, finished: now - 400 * day, archived: nil, clearedAt: nil, now: now))
        #expect(ArchiveAfter.never.archives(settled: true, finished: now, archived: now, clearedAt: nil, now: now))
        #expect(after.archives(settled: true, finished: now - 60, archived: nil, clearedAt: now, now: now))
        #expect(!after.archives(settled: false, finished: now - 9 * day, archived: now, clearedAt: now, now: now))
        #expect(!after.archives(settled: true, finished: nil, archived: nil, clearedAt: nil, now: now))
    }

    /// obid's `archived` reaches the Mac with the job, and its `{"id", "deleted": true}` event drops it.
    @Test func archivedAndDeletedComeFromObid() {
        let extras = RunnerJobExtras.of(Data(#"[{"id":"j1","archived":"2026-10-20T09:00:00Z"},{"id":"j2","archived":null}]"#.utf8))
        #expect(extras["j1"]?.archived == ISO8601DateFormatter().date(from: "2026-10-20T09:00:00Z") && extras["j2"]?.archived == nil)
        var parser = EventParser()
        for line in ["event: job", #"data: {"id":"j1","deleted":true}"#] { #expect(parser.feed(line) == nil) }
        #expect(parser.feed("") == .jobDeleted("j1"))
    }

    /// Delete task says what goes, and that nothing pushed does.
    @Test func deleteSaysWhatGoes() {
        var job = Job(id: "j", request: "r", agent: "claude", account: "default", repo: "deskree-inc/oby", branch: "oby/x",
                      base: "dev", pr: nil, kind: .build, task: "t", created: now)
        #expect(TaskMenu.deleteLine(job) == "Its worktree and local branch go for good. What's on GitHub stays: its pushed branch and pull request.")
        job.commits = 3
        job.pushed = 2
        #expect(TaskMenu.deleteLine(job).hasSuffix(" 1 commit that isn't published is lost."))
        job.pushed = nil
        #expect(TaskMenu.deleteLine(job).hasSuffix(" 3 commits that aren't published are lost."))
    }

    /// Archived's search matches a task's name, kind of work or agent, in any case.
    @Test func searchingArchived() {
        var job = Job(id: "j", request: "r", agent: "codex", account: "default", repo: "deskree-inc/oby", branch: "oby/x",
                      base: "dev", pr: nil, kind: .build, task: "t", created: now)
        job.title = "Vault tests"
        let items = SidebarSections.work(local: [], runner: [job], since: now, seen: [])
        #expect(ArchivePane.matching(items, "").count == 1 && ArchivePane.matching(items, " vault ").count == 1)
        #expect(ArchivePane.matching(items, "CODEX").count == 1 && ArchivePane.matching(items, "tasks").count == 1)
        #expect(ArchivePane.matching(items, "login").isEmpty)
        #expect(GroupPane.archivedLink == "Older ones are in Archived")
    }
}
