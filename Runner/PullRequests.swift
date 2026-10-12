import Foundation
@testable import ObyEngine

/// Read-only GitHub following, using the runner's gh login through Shell (never Agents).
@MainActor
final class PullRequests {
    static let interval: TimeInterval = 180
    private let desk: Desk
    private var polling = false
    /// Includes failed attempts, so an unavailable GitHub isn't hammered on every wake-up.
    private var attempted: [String: (url: String, date: Date)] = [:]
    var read: ([String]) async throws -> Data = { arguments in
        let result = try await Shell.run(arguments, env: ["GH_PROMPT_DISABLED": "1"], timeout: 30, as: .app)
        guard result.status == 0 else {
            // Don't store arbitrary tool output (it can contain credentials or GitHub text).
            throw Shell.Failure(message: "Couldn't refresh the pull request (gh exit \(result.status)).")
        }
        return result.out
    }

    init(desk: Desk) { self.desk = desk }

    func poll(at now: Date = .now) async {
        guard !polling else { return }
        polling = true
        defer { polling = false }
        for job in desk.pullRequestsToFollow {
            guard !Task.isCancelled, let url = job.published else { return }
            if let last = attempted[job.id], last.url == url, now.timeIntervalSince(last.date) < Self.interval { continue }
            if let checked = job.pullRequest?.checkedAt, now.timeIntervalSince(checked) < Self.interval { continue }
            attempted[job.id] = (url, now)
            do {
                let arguments = try Self.arguments(for: job)
                let data = try await read(arguments)
                let status = try Self.decode(data, at: now)
                desk.followed(job.id, published: url, pushed: job.pushed, status: status, error: nil)
                // A job the list doesn't hold changes without `Desk.replace`: a merge outside Oby is still an intervention.
                if !desk.lists(job.id) {
                    var seen = job
                    seen.pullRequest = status
                    desk.failureLog.observe(seen)
                }
                // Xcode Cloud's results on that head (#122), read with the same login.
                if status.state == .open, let head = status.head {
                    do {
                        let cloud = try await XcodeCloud.fetch(repo: job.repo, head: head, at: now, read: read)
                        await desk.cloudObserved(job.id, published: url, pushed: job.pushed, head: head, result: cloud)
                    } catch {
                        await desk.cloudObserved(job.id, published: url, pushed: job.pushed, head: head, result: nil, error: true)
                    }
                }
            } catch {
                guard !Task.isCancelled else { return }
                desk.followed(job.id, published: url, pushed: job.pushed, status: nil,
                              error: "Couldn't refresh the pull request. Will try again shortly.")
            }
        }
    }

    /// Only a published PR in this job's repository can be queried, never its input `pr`.
    nonisolated static func arguments(for job: Job) throws -> [String] {
        guard let published = job.published, let url = URLComponents(string: published),
              url.scheme == "https", url.host == "github.com", url.port == nil,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              job.repo.wholeMatch(of: /[A-Za-z0-9-]+\/[A-Za-z0-9._-]+/) != nil,
              !job.repo.contains("..") else { throw Shell.Failure(message: "Invalid published pull request.") }
        let parts = url.path.split(separator: "/")
        guard parts.count == 4, "\(parts[0])/\(parts[1])" == job.repo, parts[2] == "pull",
              let number = Int(parts[3]), number > 0 else { throw Shell.Failure(message: "Invalid published pull request.") }
        return ["gh", "pr", "view", String(number), "--repo", job.repo,
                "--json", "state,reviewDecision,mergedAt,baseRefName,headRefOid"]
    }

    nonisolated static func decode(_ data: Data, at now: Date) throws -> PullRequestStatus {
        struct Observation: Decodable {
            var state: PullRequestStatus.State
            var reviewDecision: String?
            var mergedAt: Date?
            var baseRefName: String
            var headRefOid: String?
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let value = try decoder.decode(Observation.self, from: data)
        guard !value.baseRefName.isEmpty,
              value.state != .merged || value.mergedAt != nil,
              value.state == .merged || value.mergedAt == nil else {
            throw Shell.Failure(message: "Incomplete pull request status.")
        }
        return PullRequestStatus(state: value.state,
                                 reviewDecision: value.reviewDecision.flatMap(PullRequestStatus.Review.init(rawValue:)),
                                 base: value.baseRefName, mergedAt: value.mergedAt, checkedAt: now,
                                 head: value.headRefOid.flatMap { $0.isEmpty ? nil : $0 })
    }
}
