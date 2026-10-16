import Foundation

/// What a task's card and page say (Sangam's TaskCard.tsx), from what the runner serves for a job:
/// how long it's been going, what it left behind, its stages' marks, its facts, and what its box
/// offers.
nonisolated enum TaskFacts {
    /// Minutes as "34m", or "1h 5m"; under a minute, "now".
    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int(max(0, seconds) / 60)
        if minutes < 1 { return "now" }
        return minutes < 60 ? "\(minutes)m" : "\(minutes / 60)h \(minutes % 60)m"
    }

    /// Top right of the card: how long an open task has been going; when a done one finished.
    static func ago(_ job: Job, now: Date = .now) -> String {
        if !job.isActive, let finished = job.finished {
            let text = duration(now.timeIntervalSince(finished))
            return text == "now" ? text : "\(text) ago"
        }
        return duration(now.timeIntervalSince(job.created))
    }

    /// "obi#412" from its pull request's address.
    static func pullRequest(_ published: String?) -> String? {
        guard let published, let url = URL(string: published), url.host == "github.com" else { return nil }
        let parts = url.path.split(separator: "/")
        guard parts.count >= 4, parts[2] == "pull" else { return nil }
        return "\(parts[1])#\(parts[3])"
    }

    /// What a finished task left behind, one line: its commits, its pull request, and how long it
    /// took; nil when there's none of that.
    static func resultLine(_ job: Job) -> String? {
        guard !job.isActive else { return nil }
        var parts: [String] = []
        if let commits = job.commits, commits > 0 { parts.append("\(commits) commit\(commits == 1 ? "" : "s") on \(job.branch)") }
        if let pr = pullRequest(job.published) { parts.append(pr) }
        if let finished = job.finished {
            let took = duration(finished.timeIntervalSince(job.started ?? job.created))
            if took != "now" { parts.append("Took \(took)") }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// A stage's mark on the task's page: the one being worked on pulses only while the agent works;
    /// orange while the task needs you; once done, the stage still waiting on someone else is a ring.
    enum Mark: Equatable { case done, current, needs, upcoming, skipped, failed }

    static func mark(_ stage: JobStage.State, needs: Bool, done: Bool) -> Mark {
        switch stage {
        case .done: .done
        case .failed: .failed
        case .skipped: .skipped
        case .upcoming: .upcoming
        case .current: needs ? .needs : done ? .upcoming : .current
        }
    }

    /// The facts under Details, in order: a name, its value, and whether it reads as code.
    static func facts(_ job: Job) -> [(name: String, value: String, mono: Bool)] {
        var facts: [(String, String, Bool)] = [
            ("Repository", job.repo, false), ("Branch", job.branch, true), ("Base", job.base ?? "Repository default", job.base != nil),
            ("Model", job.model.map(AgentModels.name) ?? "Account default", false),
        ]
        if job.maxRounds > 1 { facts.append(("Rounds", "Round \(job.currentRound) of \(job.maxRounds)", false)) }
        if let check = job.check { facts.append(("Done when", "\(check) passes", true)) }
        return facts
    }

    /// The page's box: a word for the agent while it can take one (it runs, or a finished one can
    /// pick its session up), as a follow-up once it's done; nil when there's nothing to tell.
    static func box(_ job: Job) -> String? {
        if job.status == .running { return "Tell \(job.agentName)…" }
        if !job.isActive && job.resumable { return "Ask for a follow-up…" }
        return nil
    }
}
