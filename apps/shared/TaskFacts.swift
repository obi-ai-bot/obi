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
        return duration(now.timeIntervalSince(job.started ?? job.created))
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

    /// `working`: its agent is at it (not queued, not finished).
    static func mark(_ stage: JobStage.State, needs: Bool, working: Bool) -> Mark {
        switch stage {
        case .done: .done
        case .failed: .failed
        case .skipped: .skipped
        case .upcoming: .upcoming
        case .current: needs ? .needs : working ? .current : .upcoming
        }
    }

    /// Whether the page has a Result: what the agent reported, what it left behind (also while a
    /// published job runs again), or something to do about it.
    static func hasResult(_ job: Job) -> Bool {
        !job.summary.isEmpty || resultLine(job) != nil || job.commits != nil || job.published != nil || job.sentLines != nil
            || job.pullRequestError != nil || job.canPublish || job.needsYou || job.dismissed != nil || job.report == true
    }

    /// What the page offers under its card.
    struct Controls: Equatable {
        var startNow = false
        var stop = false
        /// Let it go: whatever it needs you for, waiting on Publish included.
        var dismiss = false
    }

    static func controls(_ job: Job) -> Controls {
        Controls(startNow: job.waitsToStart, stop: job.isActive, dismiss: job.needsYou || job.canPublish)
    }

    /// The facts under Details, in order: a name, its value, and whether it reads as code.
    /// `mode` is the runner's word for how freely its agent works (`RunnerMode`).
    static func facts(_ job: Job, mode: String? = nil) -> [(name: String, value: String, mono: Bool)] {
        var facts: [(String, String, Bool)] = [
            ("Repository", job.repo, false), ("Branch", job.branch, true), ("Base", job.base ?? "Repository default", job.base != nil),
            ("Model", job.model.map(ModelChoice.name) ?? "Account default", false),
        ]
        if let mode = RunnerMode(mode) { facts.append(("Mode", mode.label, false)) }
        if let check = job.check { facts.append(("Done when", "\(check) passes", true)) }
        return facts
    }

    /// The page's box (Sangam's TaskView), always there: words for Oby about the task, which it
    /// passes on to the agent, or which start a follow-up of a finished one.
    static let box = "Tell Oby about this task…"

    /// What Oby answers words said on a task's page, which reached `heard` (`job` itself, its
    /// follow-up already at work, or the one they started): Sangam's `relay` (tasks.ts), as obid
    /// says it in the job's conversation (core/crates/obid/src/brain/actions.rs `told_line`).
    static func relay(_ job: Job, heard: Job, account: String) -> String {
        if heard.id != job.id && heard.followUpOf == job.id && (heard.notes ?? []).isEmpty {
            return "This one’s finished, so I started a follow-up. \(heard.agentName) has it in \(heard.repoName) on \(account)."
        }
        return "Passed to \(heard.agentName). It’ll pick that up after \((heard.rounds ?? 1) > 1 ? "this round" : "its current step")."
    }

    /// Later on a task's decision (Sangam's `answer`, tasks.ts): it stays, and comes back in an hour.
    static let laterReply = "Okay, it’ll wait. I’ll bring it back up in an hour."

}
