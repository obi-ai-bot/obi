import Foundation

/// Removes settled job worktrees without racing an agent or a check/publish/merge operation.
@MainActor
final class WorktreeCleanup {
    static let age: TimeInterval = 24 * 60 * 60

    struct Status: Equatable, Sendable {
        var lastRun: Date?
        var bytes: Int64
        var path: String
    }

    let clock: () -> Date
    var remove: (Job) async -> Bool
    private(set) var status: Status

    init(root: URL = Workspace.root, clock: @escaping () -> Date = { Date.now }) {
        self.clock = clock
        let jobs = root.appending(path: "jobs")
        self.status = Status(lastRun: nil, bytes: Self.size(of: jobs), path: jobs.path)
        self.remove = { job in
            let clone = Workspace.clone(job.repo)
            let worktree = Workspace.worktree(job.id)
            guard FileManager.default.fileExists(atPath: worktree.path),
                  FileManager.default.fileExists(atPath: clone.appending(path: ".git").path) else { return false }
            guard (try? await Shell.ok(["git", "-C", clone.path, "worktree", "remove", "--force", worktree.path])) != nil else { return false }
            _ = try? await Shell.run(["git", "-C", clone.path, "branch", "-D", "--", job.branch])
            return true
        }
    }

    func run(jobs: [Job], inUse: (String) -> Bool) async {
        let now = clock()
        for job in jobs where shouldRemove(job, now: now) && !inUse(job.id) { _ = await remove(job) }
        status = Status(lastRun: now, bytes: Self.size(of: URL(filePath: status.path)), path: status.path)
    }

    private func shouldRemove(_ job: Job, now: Date) -> Bool {
        if job.reviewOf != nil, job.review != nil { return true }
        guard let finished = job.finished, finished <= now.addingTimeInterval(-Self.age), !job.isActive, !job.needsYou,
              job.dismissed != nil || job.status == .stopped || settledPullRequest(job) else { return false }
        return true
    }

    private func settledPullRequest(_ job: Job) -> Bool {
        guard let state = job.pullRequest?.state else { return false }
        return state == .merged || state == .closed
    }

    private static func size(of url: URL) -> Int64 {
        guard let items = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey], options: [.skipsHiddenFiles]) else { return 0 }
        return items.compactMap { item -> Int64? in
            guard let url = item as? URL, let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey]) else { return nil }
            return Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }.reduce(0, +)
    }
}
