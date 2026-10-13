import Foundation

/// A stable wire format: clients render these stages; Engine alone derives them.
nonisolated struct JobStage: Codable, Equatable, Identifiable, Sendable {
    enum ID: String, Codable, Sendable { case prepare, work, check, publish, review, cloud, merged }
    enum State: String, Codable, Sendable { case done, current, upcoming, failed, skipped }
    var id: ID
    var title: String
    var state: State
    var detail: String?
    var reason: String?
}

nonisolated struct JobPipeline: Codable, Equatable, Sendable {
    var stages: [JobStage]
    /// One-based position among the displayed stages, including skipped stages.
    var number: Int
    var total: Int
    var label: String { "Stage \(number) of \(total)" }
}

/// The most recent successful observation of the published PR, never an agent's claim.
nonisolated struct PullRequestStatus: Codable, Equatable, Sendable {
    enum State: String, Codable, Sendable { case open = "OPEN", closed = "CLOSED", merged = "MERGED" }
    enum Review: String, Codable, Sendable {
        case waiting = "REVIEW_REQUIRED", changesRequested = "CHANGES_REQUESTED", approved = "APPROVED"
    }
    var state: State
    var reviewDecision: Review?
    var base: String
    var mergedAt: Date?
    var checkedAt: Date
    /// The pull request's head commit as GitHub has it, or nil (older observations): one Oby didn't
    /// push is an intervention (Engine/Failures.swift).
    var head: String? = nil
}

extension Job {
    /// The last actual phase survives failure, cancellation and restart. Legacy jobs have no phase.
    nonisolated var pipeline: JobPipeline {
        typealias Stage = JobStage
        let phase = phase ?? (status == .queued || (started == nil && status != .done && published == nil) ? .prepare : .work)
        let stopped = status == .failed || status == .stopped || status == .interrupted
        let failure = summary.isEmpty ? status.rawValue.capitalized : summary
        let working = isActive && phase == .work
        var stages: [Stage] = [
            Stage(id: .prepare, title: "Prepare", state: .upcoming, detail: "Clone and worktree"),
            Stage(id: .work, title: "Work", state: .upcoming,
                  detail: "Round \(currentRound) of \(max(currentRound, maxRounds))" + (working && !step.isEmpty ? " · \(step)" : "")),
        ]
        if let check, !check.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            stages.append(Stage(id: .check, title: "Check", state: .upcoming, detail: check))
        }
        stages += [Stage(id: .publish, title: "Publish", state: .upcoming, detail: "Secret scan, push and pull request"),
                   Stage(id: .review, title: "Review", state: .upcoming, detail: "Waiting for review"),
                   Stage(id: .merged, title: "Merged into \(pullRequest?.base ?? base ?? "dev")", state: .upcoming)]
        if xcodeCloud != nil {
            stages.insert(Stage(id: .cloud, title: "Xcode Cloud", state: .upcoming), at: stages.count - 1)
        }
        func set(_ id: Stage.ID, _ state: Stage.State, detail: String? = nil, reason: String? = nil) {
            guard let index = stages.firstIndex(where: { $0.id == id }) else { return }
            stages[index].state = state
            if let detail { stages[index].detail = detail }
            stages[index].reason = reason
        }
        let phaseIndex = stages.firstIndex(where: { $0.id == phase }) ?? 1
        for index in stages.indices where index < phaseIndex { stages[index].state = .done }
        if isActive {
            set(phase, .current, detail: phase == .prepare && !step.isEmpty ? step : nil)
            if phase == .publish { set(.publish, .current, detail: publishStep?.detail ?? "Secret scan") }
        } else if stopped {
            set(phase, .failed, reason: failure)
            for index in stages.indices where index > phaseIndex { stages[index].state = .skipped }
        } else {
            set(.prepare, .done)
            set(.work, .done)
            set(.check, .done)
            if canPublish {
                set(.publish, publishError == nil ? .current : .failed,
                    detail: publishStep?.detail ?? "Ready to publish", reason: publishError)
            } else if published == nil {
                for id in [Stage.ID.publish, .review, .merged] { set(id, .skipped) }
            }
        }
        // A PR from an earlier round doesn't complete the current work/check/publish.
        if published != nil && !isActive && !stopped && !canPublish {
            set(.publish, .done, detail: "Secret scan clean · pushed · pull request opened")
            switch pullRequest?.state {
            case .merged:
                // GitHub has no decision (or still wants one) when the PR merged without a review:
                // then Oby's own verdict, if it gave one.
                let detail = switch pullRequest?.reviewDecision {
                case .approved: "Approved"
                case .changesRequested: "Review complete"
                case .waiting, nil: review.map { $0.verdict == .approved ? "Approved by Oby" : "Oby requested changes" } ?? "Merged without review"
                }
                set(.review, .done, detail: detail)
                set(.merged, .done)
            case .closed:
                set(.review, .failed, reason: "Pull request closed without merging.")
                set(.merged, .skipped)
            case .open, nil:
                switch pullRequest?.reviewDecision {
                case .approved:
                    set(.review, .done, detail: "Approved")
                    if review?.verdict == .approved {
                        let merge = mergeProgress
                        set(.merged, merge.state, detail: merge.detail, reason: merge.reason)
                    } else {
                        set(.merged, .current, detail: "Waiting to merge")
                    }
                case .changesRequested:
                    set(.review, .failed, detail: "Changes requested", reason: "The reviewer requested changes.")
                case .waiting, nil:
                    // GitHub has no decision: Oby's own review stands in (Engine/Review.swift).
                    if reviewing != nil {
                        set(.review, .current, detail: "Oby is reviewing")
                    } else if let review, review.verdict == .approved {
                        set(.review, .done, detail: "Approved by Oby")
                        // The Mac checks it, then Oby merges it (Engine/Checks.swift).
                        let merge = mergeProgress
                        set(.merged, merge.state, detail: merge.detail, reason: merge.reason)
                    } else if let review {
                        set(.review, .failed, detail: "Changes requested",
                            reason: review.stopsHere ? review.stopReason : "Oby requested changes.")
                    } else if let reviewError {
                        set(.review, .current, detail: reviewError.hasPrefix(Review.waiting) ? reviewError : "Waiting for review · \(reviewError)")
                    } else {
                        set(.review, .current, detail: pullRequest == nil ? "Waiting for GitHub status" : "Waiting for review")
                    }
                }
            }
        }
        if let cloud = xcodeCloud, published != nil {
            let current = cloud.head == (pullRequest?.head ?? pushedHead)
            let state: Stage.State = current && cloud.state == .passed && xcodeCloudError == nil ? .done
                : current && cloud.state == .failed ? .failed : .current
            let waitingForRebase = cloud.conflict && isActive
            set(.cloud, state, detail: state == .done ? "Passed" : waitingForRebase ? "Xcode Cloud: waiting for a rebase onto \(base ?? "dev")" : state == .failed ? "Failed" : "Pending",
                reason: xcodeCloudError ?? (state == .failed ? cloud.problem ?? cloud.details : nil))
        }
        // The user let it go: nothing is published, reviewed or merged. A pull request from an
        // earlier round keeps its own progress; a failed publish keeps its reason.
        if dismissed != nil, !isActive, published == nil || stopped, let publish = stages.firstIndex(where: { $0.id == .publish }) {
            stages[publish].state = .skipped
            stages[publish].detail = "Dismissed"
            if phase != .publish || !stopped { stages[publish].reason = nil }
            for index in stages.indices where index > publish { stages[index].state = .skipped }
        }
        let position = stages.firstIndex { $0.state == .current || $0.state == .failed }
            ?? stages.lastIndex { $0.state == .done || $0.state == .skipped } ?? 0
        return JobPipeline(stages: stages, number: position + 1, total: stages.count)
    }
}
