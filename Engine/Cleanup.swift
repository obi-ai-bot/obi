import Foundation

/// Removes settled job worktrees without racing an agent or a check/publish/merge operation.
@MainActor
final class WorktreeCleanup {
    static let age: TimeInterval = 24 * 60 * 60

    enum WorktreeRemoval: Equatable, Sendable {
        case removed
        case alreadyGone
        case failed
    }

    struct Status: Equatable, Sendable {
        var lastRun: Date?
        var bytes: Int64
        var path: String
    }

    let clock: () -> Date
    var remove: (Job) async -> WorktreeRemoval
    var removeBranch: (Job) async -> Void
    private(set) var status: Status

    init(root: URL = Workspace.root, clock: @escaping () -> Date = { Date.now }) {
        self.clock = clock
        let jobs = root.appending(path: "jobs")
        self.status = Status(lastRun: nil, bytes: Self.size(of: jobs), path: jobs.path)
        self.remove = { job in
            let clone = Workspace.clone(job.repo)
            let worktree = Workspace.worktree(job.id)
            guard FileManager.default.fileExists(atPath: clone.appending(path: ".git").path) else { return .failed }
            guard FileManager.default.fileExists(atPath: worktree.path) else { return .alreadyGone }
            do {
                _ = try await Shell.ok(["git", "-C", clone.path, "worktree", "remove", "--force", worktree.path])
                return .removed
            } catch {
                return .failed
            }
        }
        self.removeBranch = { job in
            let clone = Workspace.clone(job.repo)
            _ = try? await Shell.run(["git", "-C", clone.path, "branch", "-D", "--", job.branch])
        }
    }

    func run(jobs: [Job], inUse: (String) -> Bool) async {
        let now = clock()
        let byID = Dictionary(jobs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for job in jobs where shouldRemove(job, authors: byID, now: now) && !inUse(job.id) {
            guard await remove(job) != .failed else { continue }
            if shouldRemoveBranch(job, authors: byID) { await removeBranch(job) }
        }
        status = Status(lastRun: now, bytes: Self.size(of: URL(filePath: status.path)), path: status.path)
    }

    private func shouldRemove(_ job: Job, authors: [String: Job], now: Date) -> Bool {
        if let authorID = job.reviewOf, authors[authorID]?.review?.job == job.id { return true }
        guard let finished = job.finished, finished <= now.addingTimeInterval(-Self.age), !job.isActive, !job.needsYou,
              job.dismissed != nil || job.status == .stopped || settledPullRequest(job) else { return false }
        return true
    }

    private func settledPullRequest(_ job: Job) -> Bool {
        guard let state = job.pullRequest?.state else { return false }
        return state == .merged || state == .closed
    }

    private func shouldRemoveBranch(_ job: Job, authors: [String: Job]) -> Bool {
        guard let authorID = job.reviewOf else { return true }
        guard let author = authors[authorID] else { return false }
        return settledPullRequest(author)
    }

    private static func size(of url: URL) -> Int64 {
        guard let items = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey], options: [.skipsHiddenFiles]) else { return 0 }
        return items.compactMap { item -> Int64? in
            guard let url = item as? URL, let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey]) else { return nil }
            return Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }.reduce(0, +)
    }
}
