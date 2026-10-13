import Foundation
#if canImport(OSLog)
import OSLog
#endif

/// The runner's journal for picking its jobs up after any restart (a crash, a reboot, systemd, a
/// manual deploy or its own update): the message each job's agent was about to get, kept from the
/// moment Oby hands it over until the agent's turn ends, and when each job was picked up again.
/// The Mac's desk has none: quitting Oby there leaves its jobs interrupted.
final class Restarts {
    /// A job picked up this many times within `window` stays interrupted at the next restart.
    static let most = 2
    static let window: TimeInterval = 30 * 60

    /// What an agent picked up after a restart hears before the message it was about to get.
    static let notice = "Oby's runner restarted while you were working, so your last turn was cut short. Your worktree, branch and commits are as you left them: pick up where you left off, then finish with a short summary as asked."
    static let noticeWithMessage = notice + "\n\nThis is the message you were given (or about to be given) when it restarted. If you had already taken it up, carry on with it:"
    /// Why a job the runner kept going down with stays interrupted.
    static let looping = "Oby's runner restarted \(most + 1) times in \(Int(window / 60)) minutes while this ran, so Oby left it here. Tell it something to carry on."

    struct Entry: Codable {
        var message: String?
        var resumed: [Date]?
        /// The runner restarted on purpose (its own update) while this job ran: not a crash.
        var planned: Bool?
    }

    let file: URL
    private var entries: [String: Entry]

    init(file: URL) {
        self.file = file
        entries = (try? JSONDecoder().decode([String: Entry].self, from: Data(contentsOf: file))) ?? [:]
    }

    /// The message the job's agent was about to get, or is taking up now.
    func message(_ id: String) -> String? { entries[id]?.message }

    /// Oby hands the job's agent `message`: it replaces what was pending, or joins it (`adding`),
    /// when the agent hasn't taken the first up yet.
    func give(_ id: String, _ message: String, adding: Bool = false) {
        let previous = adding ? entries[id]?.message : nil
        entries[id, default: Entry()].message = previous.map { $0 + "\n\n" + message } ?? message
        save()
    }

    /// The agent's turn ended: what it was given is in its session now.
    func took(_ id: String) {
        guard entries[id]?.message != nil else { return }
        entries[id]?.message = nil
        save()
    }

    /// The job ended: nothing of it is picked up again.
    func forget(_ id: String) {
        guard entries.removeValue(forKey: id) != nil else { return }
        save()
    }

    /// The runner is about to restart on purpose (its own update): picking these jobs up again
    /// doesn't count towards a crash loop.
    func planRestart(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        for id in ids { entries[id, default: Entry()].planned = true }
        save()
    }

    /// Whether the job may be picked up again `now`: not when it was twice within `window` already
    /// (the runner is crashing in a loop). Counts this time when it may, unless the restart was planned.
    func pickUp(_ id: String, now: Date = .now) -> Bool {
        if entries[id]?.planned == true {
            entries[id]?.planned = nil
            save()
            return true
        }
        let recent = (entries[id]?.resumed ?? []).filter { now.timeIntervalSince($0) < Self.window }
        guard recent.count < Self.most else { return false }
        entries[id, default: Entry()].resumed = recent + [now]
        save()
        return true
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(entries).write(to: file, options: .atomic)
        } catch {
            Logger.jobs.error("couldn't save \(self.file.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }
}

extension Desk {
    /// The runner started again, after any restart: every job that was queued or running when it
    /// went down carries on in its own session and worktree, hearing the restart notice, then the
    /// message it was about to get. One picked up twice in the last 30 minutes stays interrupted,
    /// with one inbox item. Jobs waiting for an answer or an OK, or stopped, were never in `wentDown`. Then
    /// reviews whose verdict didn't reach their author are applied (`resumeReviews`).
    func resumeAfterRestart() {
        resumeXcodeBuilds()
        guard let restarts else { return }
        let ids = wentDown
        wentDown = []
        // Every job is still active as it was, so jobs touching the same files wait in order.
        for id in ids {
            guard var job = job(id), job.isActive else { continue }
            let message = restarts.message(id)
            // Waiting for its `startWhen`, never started (#216): no agent of its crashed, so it
            // waits again whatever the restarts.
            let neverRan = job.waitsToStart && job.session == nil && message == nil
            guard neverRan || restarts.pickUp(id) else {
                Logger.jobs.notice("job \(id, privacy: .public): picked up \(Restarts.most) times in 30 minutes; left interrupted")
                job.status = .interrupted
                job.finished = .now
                job.step = ""
                job.summary = Restarts.looping + (job.summary.isEmpty ? "" : "\n\n" + job.summary)
                replace(job)
                if job.reviewOf != nil { reviewEnded(job) }
                continue
            }
            job.publishStep = nil
            // What it waited for before the restart is found again (`startOrWait`), or holds it no more.
            job.waiting = nil
            if let session = job.session {
                job.status = .running
                job.phase = .work
                job.step = "Picking up after the runner restarted"
                replace(job)
                run(job, prompt: message ?? "", resume: session, notice: message == nil ? Restarts.notice : Restarts.noticeWithMessage)
            } else if let message {
                // Started, or taken over by another account, before its agent had a session.
                job.status = .running
                job.phase = .work
                replace(job)
                run(job, prompt: message)
            } else if job.startCommit != nil {
                job.status = .queued
                // Set up before the restart: what merged meanwhile comes first.
                startOrWait(job, catchUp: true)
            } else {
                // A setup the restart cut short: its worktree gets ready again.
                replace(job, save: false)
                let job = job
                Task {
                    do {
                        var prepared = try await prepare(job)
                        guard let latest = self.job(job.id), latest.status == .queued else { return }
                        // Moved meanwhile: it starts where it was moved to.
                        (prepared.agent, prepared.account, prepared.model, prepared.moves) = (latest.agent, latest.account, latest.model, latest.moves)
                        (prepared.startWhen, prepared.question) = (latest.startWhen, latest.question)
                        startOrWait(prepared)
                    } catch { finish(job.id, .failed, "Couldn't get \(job.repoName) ready: \(error.localizedDescription)") }
                }
            }
        }
        // End-of-turn work the restart cut short: a review's verdict reaching its author. Merges
        // carry on with the refresh (`resumeChecks`), and a publish with its job, still running.
        resumeReviews()
    }
}
