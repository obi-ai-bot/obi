import Foundation
#if canImport(OSLog)
import OSLog
#endif

/// Something Oby sent out for a job: a push, a pull request opened or brought up to date, a
/// comment. The job's report lists them, oldest first, and the log keeps one line each. Ids only
/// (the commit, the URL), never what was sent.
nonisolated struct Outgoing: Codable, Equatable, Sendable {
    enum Action: String, Codable, Sendable { case push, pullRequest, pullRequestEdit, comment }

    var action: Action
    var repo: String
    /// The commit pushed, or the pull request's or the comment's URL.
    var id: String
    /// The branch a push went to; nil for the rest.
    var branch: String?
    var date = Date.now

    /// One line of the report: "Pushed 1a2b3c4 to oby/fix-75 in deskree-inc/oby".
    var line: String {
        switch action {
        case .push: "Pushed \(id.prefix(7)) to \(branch ?? "its branch") in \(repo)"
        case .pullRequest: "Opened pull request \(id)"
        case .pullRequestEdit: "Updated the description of \(id)"
        case .comment: "Commented \(id)"
        }
    }
}

extension Job {
    /// The report's list of what Oby sent out for the job, one line each, or nil when nothing went out.
    var sentLines: String? {
        guard let outgoing, !outgoing.isEmpty else { return nil }
        return "Sent by Oby:\n" + outgoing.map { "- \($0.line)" }.joined(separator: "\n")
    }
}

extension Desk {
    /// Oby sent something out for the job: its report lists it, whatever state the job is in now.
    func sent(_ id: String, _ outgoing: Outgoing) {
        Logger.jobs.notice("job \(id, privacy: .public): sent \(outgoing.action.rawValue, privacy: .public) \(outgoing.repo, privacy: .public) \(outgoing.branch ?? "", privacy: .public) \(outgoing.id, privacy: .public)")
        guard var job = job(id) else { return }
        job.outgoing = (job.outgoing ?? []) + [outgoing]
        replace(job)
    }
}
