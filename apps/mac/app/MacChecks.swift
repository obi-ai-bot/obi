import Foundation
import Observation
import OSLog

/// Merge checks on this Mac (#66, Engine/Checks.swift): while Oby runs and follows the runner,
/// it takes the checks the runner queues when Oby's review approves a pull request, runs them in a
/// clean worktree of the pull request's head, one at a time, and reports pass or fail with the
/// failing tests' names. It also takes the Apple checks agents ask for mid-round (#118,
/// Engine/AppleChecks.swift), first: their commits come from the runner as a git bundle. Settings ›
/// Runner turns each on; both are off by default since the launch build (AGENTS.md, 2026-10-23).
@Observable
final class MacChecks {
    /// Settings › Runner: "Run merge checks on this Mac", off by default.
    static let setting = "runMergeChecks"
    static var enabled: Bool { UserDefaults.standard.object(forKey: setting) as? Bool ?? false }
    /// Settings › Runner: "Build and test agents' work on this Mac", off by default. Agents' code
    /// runs here before Oby's review has read it.
    static let appleSetting = "runAppleChecks"
    static var appleEnabled: Bool { UserDefaults.standard.object(forKey: appleSetting) as? Bool ?? false }

    /// Registers both defaults as off, so Settings › Runner's toggles (whose own @AppStorage
    /// defaults say on) show what's true: a registered default wins over @AppStorage's.
    init() {
        UserDefaults.standard.register(defaults: [Self.setting: false, Self.appleSetting: false])
    }
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
    /// while one runs here already, or with both settings off.
    func look(_ runner: Runner) {
        guard Self.enabled || Self.appleEnabled, !busy else { return }
        busy = true
        Task {
            defer {
                busy = false
                current = nil
            }
            do {
                let name = await Self.name()
                while Self.enabled || Self.appleEnabled,
                      let check = try await runner.nextCheck(mac: name, merge: Self.enabled, apple: Self.appleEnabled) {
                    current = check
                    Logger.feed.notice("check \(check.id, privacy: .public): pull request #\(check.pr, privacy: .public) at \(check.head, privacy: .public)")
                    let report: MacCheck.Report
                    if check.isApple {
                        // No commits from the runner: the checkout says so, and the check couldn't run.
                        report = await MacCheck.run(check, bundle: try? await runner.bundle(check.id))
                    } else {
                        report = await MacCheck.run(check)
                    }
                    current = nil
                    do {
                        _ = try await runner.report(check.id, report)
                    } catch let error as RunnerError where error.status == 404 || error.status == 409 {
                        // The agent asked again for a newer commit meanwhile: this result has no one waiting.
                        Logger.feed.notice("check \(check.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    }
                }
            } catch {
                // The runner went away mid-check: it offers the check again once its lease runs out.
                Logger.feed.error("merge checks: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
