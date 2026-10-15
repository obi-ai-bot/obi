import ActivityKit
import Foundation
import OSLog

/// Keeps the Live Activity in step with the runner's jobs: one activity while any agent works,
/// ended with how the last job finished. While the app runs it updates the activity itself; while
/// it's suspended the runner pushes (Runner/Push.swift) to the tokens this hands it, and can start
/// the activity by push-to-start when a job begins with the app closed.
enum JobsActivity {
    private static var current: Activity<ObyActivity>? { open.first }

    private static var open: [Activity<ObyActivity>] {
        Activity<ObyActivity>.activities.filter { $0.activityState == .active || $0.activityState == .stale }
    }

    /// The runner said it pushes, so the Lock Screen stays current while the app is away.
    private static var pushed = false
    private static var runner: () -> Runner? = { nil }
    /// Activities whose push tokens are already followed.
    private static var watched: Set<String> = []

    static func sync(_ jobs: [Job]) async {
        // A push-started activity and the app's own can meet: keep one.
        for extra in open.dropFirst() { await extra.end(nil, dismissalPolicy: .immediate) }
        let active = jobs.filter(\.isActive)
        // A job working first, and only those count as working: not the ones waiting their turn (#238).
        if let job = active.first(where: \.isWorking) ?? active.first {
            let state = state(job, working: active.count(where: \.isWorking))
            if let current {
                guard current.content.state != state || current.content.staleDate != nil else { return }
                await current.update(ActivityContent(state: state, staleDate: nil))
            } else if ActivityAuthorizationInfo().areActivitiesEnabled {
                let content = ActivityContent(state: state, staleDate: nil)
                do {
                    let activity: Activity<ObyActivity>
                    do {
                        activity = try Activity.request(attributes: ObyActivity(), content: content, pushType: .token)
                    } catch {
                        // Without the push entitlement, the activity still works while the app runs.
                        Logger.phone.error("a Live Activity with push failed: \(error.localizedDescription, privacy: .public)")
                        activity = try Activity.request(attributes: ObyActivity(), content: content)
                    }
                    watch(activity)
                } catch {
                    Logger.phone.error("starting the Live Activity failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        } else if let current,
                  let last = jobs.max(by: { ($0.finished ?? .distantPast) < ($1.finished ?? .distantPast) }) {
            // The Lock Screen keeps how it ended for 15 minutes after the job finished.
            let end = (last.finished ?? .now).addingTimeInterval(15 * 60)
            await current.end(ActivityContent(state: state(last, working: 0), staleDate: nil), dismissalPolicy: .after(end))
        }
    }

    /// The app stopped following the runner: a minute later the Lock Screen says the step may be
    /// old, unless the runner pushes.
    static func markStale() {
        guard !pushed, let current, current.content.staleDate == nil else { return }
        Task { await current.update(ActivityContent(state: current.content.state, staleDate: .now.addingTimeInterval(60))) }
    }

    /// Hands the runner every push token, now and as they change: each activity's (the ones open at
    /// launch, the app's own and push-started ones) and the push-to-start token.
    static func watchTokens(runner: @escaping () -> Runner?) {
        self.runner = runner
        for activity in Activity<ObyActivity>.activities { watch(activity) }
        Task {
            for await activity in Activity<ObyActivity>.activityUpdates { watch(activity) }
        }
        Task {
            for await token in Activity<ObyActivity>.pushToStartTokenUpdates { await register(token, kind: "start") }
        }
    }

    private static func watch(_ activity: Activity<ObyActivity>) {
        guard watched.insert(activity.id).inserted else { return }
        Task {
            for await token in activity.pushTokenUpdates { await register(token, kind: "update") }
        }
    }

    private static func register(_ token: Data, kind: String) async {
        guard let runner = runner() else { return }
        do {
            pushed = try await runner.registerActivity(token: token, kind: kind)
        } catch {
            Logger.phone.error("handing the runner a \(kind, privacy: .public) token failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func state(_ job: Job, working: Int) -> ObyActivity.ContentState {
        ObyActivity.ContentState(working: working, title: job.heading, line: job.line.isEmpty ? "Starting…" : job.line,
                                 started: job.started ?? job.created, status: job.isWaiting ? "waiting" : job.status.rawValue, agent: job.agent)
    }
}
