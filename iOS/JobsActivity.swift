import ActivityKit
import Foundation
import OSLog

/// Keeps the Live Activity in step with the runner's jobs: one activity while any agent works,
/// ended with how the last job finished.
// ponytail: updated only while the app runs; after that the Lock Screen keeps the last step and the
// clock keeps ticking. Live updates in the background need push from the Oby platform (F11, spike #27).
enum JobsActivity {
    private static var current: Activity<ObyActivity>? {
        Activity<ObyActivity>.activities.first { $0.activityState == .active || $0.activityState == .stale }
    }

    static func sync(_ jobs: [Job]) {
        let active = jobs.filter(\.isActive)
        if let job = active.first {
            let state = state(job, working: active.count)
            if let current {
                guard current.content.state != state || current.content.staleDate != nil else { return }
                Task { await current.update(ActivityContent(state: state, staleDate: nil)) }
            } else if ActivityAuthorizationInfo().areActivitiesEnabled {
                do {
                    _ = try Activity.request(attributes: ObyActivity(), content: ActivityContent(state: state, staleDate: nil))
                } catch {
                    Logger.phone.error("starting the Live Activity failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        } else if let current,
                  let last = jobs.max(by: { ($0.finished ?? .distantPast) < ($1.finished ?? .distantPast) }) {
            // The Lock Screen keeps how it ended for 15 minutes after the job finished.
            let end = (last.finished ?? .now).addingTimeInterval(15 * 60)
            Task { await current.end(ActivityContent(state: state(last, working: 0), staleDate: nil), dismissalPolicy: .after(end)) }
        }
    }

    /// The app stopped following the runner: a minute later the Lock Screen says the step may be old.
    static func markStale() {
        guard let current, current.content.staleDate == nil else { return }
        Task { await current.update(ActivityContent(state: current.content.state, staleDate: .now.addingTimeInterval(60))) }
    }

    private static func state(_ job: Job, working: Int) -> ObyActivity.ContentState {
        ObyActivity.ContentState(working: working, title: job.title, line: job.line.isEmpty ? "Starting…" : job.line,
                                 started: job.started ?? job.created, status: job.status.rawValue, agent: job.agent)
    }
}
