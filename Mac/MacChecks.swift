import Foundation
import Observation
import OSLog

/// Merge checks on this Mac (#66, Engine/Checks.swift): while Oby runs and follows the runner,
/// it takes the checks the runner queues when Oby's review approves a pull request, runs them in a
/// clean worktree of the pull request's head, one at a time, and reports pass or fail with the
/// failing tests' names. Settings › Runner turns it off.
@Observable
final class MacChecks {
    /// Settings › Runner: "Run merge checks on this Mac", on by default.
    static let setting = "runMergeChecks"
    static var enabled: Bool { UserDefaults.standard.object(forKey: setting) as? Bool ?? true }
    /// What this Mac calls itself in the check's results, like "Wellingtons-MacBook-Pro". Off the
    /// main actor: looking the host name up can block.
    @concurrent static func name() async -> String {
        let host = ProcessInfo.processInfo.hostName
        return host.hasSuffix(".local") ? String(host.dropLast(".local".count)) : host
    }

    /// The check running here now, or nil.
    private(set) var current: MacCheck?
    @ObservationIgnored private var busy = false

    /// Asks the runner for checks and runs them, one after another, until none waits. Nothing
    /// while one runs here already, or with the setting off.
    func look(_ runner: Runner) {
        guard Self.enabled, !busy else { return }
        busy = true
        Task {
            defer {
                busy = false
                current = nil
            }
            do {
                let name = await Self.name()
                while Self.enabled, let check = try await runner.nextCheck(mac: name) {
                    current = check
                    Logger.feed.notice("check \(check.id, privacy: .public): pull request #\(check.pr, privacy: .public) at \(check.head, privacy: .public)")
                    let report = await MacCheck.run(check)
                    current = nil
                    _ = try await runner.report(check.id, report)
                }
            } catch {
                // The runner went away mid-check: it offers the check again once its lease runs out.
                Logger.feed.error("merge checks: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
