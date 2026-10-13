import Foundation
import Crypto
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
@testable import ObyEngine

/// Owns a checkout outside every agent sandbox. A commit that failed is tried once, even across
/// restarts; one a restart cut short is tried again. Jobs carry on after the restart like after any
/// other (`Desk.resumeAfterRestart`, Engine/Restarts.swift). Updates are batched (#212): a newer
/// `dev` commit replaces the one waiting to install, and the runner restarts for an update at most
/// once every `spacing`, unless it brings the fix of one of Oby's own failures.
@MainActor
final class Updates {
    static let interval: TimeInterval = 180
    static let drainLimit: TimeInterval = 30 * 60
    static let spacing: TimeInterval = 15 * 60

    struct State: Codable {
        /// The last commit that failed to build, test or install: not tried again.
        var failed: String?
        var installed: String?
        var digest: String?
        /// The commit whose `.build` is the warm cache in `source`.
        var cacheCommit: String?
        /// Fetching `dev` fails since the inbox last heard: one item per outage.
        var outage: Bool?
        /// When the runner last restarted to install an update: the next waits `spacing` from then.
        var restarted: Date?
    }
    struct Status: Encodable {
        var commit: String?
        var waiting: String?
        var phase: String

        enum CodingKeys: String, CodingKey { case commit, waiting, phase }
        func encode(to encoder: any Encoder) throws {
            var keys = encoder.container(keyedBy: CodingKeys.self)
            try keys.encode(commit, forKey: .commit)
            try keys.encode(waiting, forKey: .waiting)
            try keys.encode(phase, forKey: .phase)
        }
    }

    let desk: Desk
    let root: URL
    let binary: URL
    private(set) var state: State
    private(set) var status: Status
    private var polling = false
    private var drainStarted: Date?
    /// The tested executable, kept outside the checkout (a newer commit builds there), and its commit.
    private var candidate: URL?
    private var ready: String?
    /// The candidate brings the fix of one of Oby's own failures: it doesn't wait `spacing`.
    private var urgent = false
    var now: () -> Date = Date.init
    /// Whether a fix of one of Oby's own failures merged into dev since the date (Engine/Failures.swift). Tests put in their own.
    var fixesFailure: (Date) -> Bool
    /// Fake commands and install/restart in tests. Production commands never enter Agents.sandboxed.
    var command: ([String], URL, [String: String?]) async throws -> String = { args, directory, env in
        let result = try await Shell.run(args, in: directory, env: env, timeout: 1800)
        guard result.status == 0, !result.timedOut else {
            let output = [result.text, result.err].filter { !$0.isEmpty }.joined(separator: "\n")
            let diagnostics = args.prefix(2) == ["swift", "build"] ? Updates.compilerDiagnostics(output) : ""
            let reason = result.timedOut ? "timed out" : "exit \(result.status)"
            throw Shell.Failure(message: diagnostics.isEmpty ? reason : diagnostics)
        }
        return result.text
    }
    /// `swift test` needs its output even on failure, both to identify failed tests and to report
    /// compiler diagnostics without exposing the rest of a potentially sensitive build log.
    var testCommand: ([String], URL, [String: String?]) async throws -> Shell.Output = { args, directory, env in
        try await Shell.run(args, in: directory, env: env, timeout: 1800)
    }
    var loadAverage: () -> Double = {
        var values = [Double](repeating: 0, count: 1)
        return values.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return 0 }
            return getloadavg(base, 1) == 1 ? buffer[0] : 0
        }
    }
    var wait: (Duration) async -> Void = { duration in try? await Task.sleep(for: duration) }
    var install: (URL, URL) throws -> Void = Updates.install
    var restart: () -> Void = { exit(75) } // Restart=on-failure in the user service.

    init(desk: Desk, root: URL = Workspace.root.appending(path: "updates"),
         binary: URL = URL(filePath: CommandLine.arguments[0]).standardizedFileURL) {
        self.desk = desk
        self.root = root
        self.binary = binary
        fixesFailure = { [weak desk] since in desk?.failureLog.fixMerged(since: since) ?? false }
        state = (try? JSONDecoder().decode(State.self, from: Data(contentsOf: root.appending(path: "state.json")))) ?? State()
        // A manual install must not report the previous executable's commit.
        let commit = state.digest == (try? Self.digest(binary)) ? state.installed : nil
        status = Status(commit: commit, waiting: nil, phase: "idle")
        desk.retryUpdate = { [weak self] in self?.retry() }
    }

    private func save() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode(state).write(to: root.appending(path: "state.json"), options: .atomic)
    }

    func poll() async {
        guard !polling else { return }
        polling = true
        defer { polling = false }
        var step = "fetch dev"
        var head: String?
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let source = root.appending(path: "source")
            if !FileManager.default.fileExists(atPath: source.appending(path: ".git").path) {
                _ = try await command(["git", "clone", "--single-branch", "--branch", "dev",
                                       "https://github.com/deskree-inc/oby.git", source.path], root, [:])
            }
            _ = try await command(["git", "fetch", "origin", "dev"], source, [:])
            let commit = try await command(["git", "rev-parse", "refs/remotes/origin/dev"], source, [:])
            // The outage is over: the next one reaches the inbox again.
            if state.outage == true {
                state.outage = nil
                try save()
            }
            // Running already, waiting to install, or it failed: nothing new.
            guard commit != status.commit, commit != state.failed, commit != ready else { return deployIfReady() }
            // A newer commit replaces the one waiting to install, rather than restart twice: it waits
            // for this one's build and tests, and a drain under way carries on meanwhile.
            head = commit
            status.waiting = commit
            status.phase = "building"
            step = "checkout dev"
            _ = try await command(["git", "reset", "--hard", commit], source, [:])
            _ = try await command(["git", "clean", "-fd"], source, [:])
            step = "swift build -c release"
            _ = try await command(["swift", "build", "-c", "release"], source, [:])
            try Data(commit.utf8).write(to: root.appending(path: "cache-commit"), options: .atomic)
            state.cacheCommit = commit
            step = "swift test"
            // Like a Mac check, the tests' Obys get a throwaway home, never the runner's own data.
            let home = FileManager.default.temporaryDirectory.appending(path: "oby-update-home-\(commit.prefix(12))")
            try? FileManager.default.removeItem(at: home)
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: home) }
            let result = try await testCommand(["swift", "test"], source, MacCheck.home(home))
            if result.status != 0 || result.timedOut || result.terminatedBySignal {
                let output = [result.text, result.err].filter { !$0.isEmpty }.joined(separator: "\n")
                guard !result.timedOut, !result.terminatedBySignal else {
                    let reason = result.timedOut ? "timed out" : "terminated by signal"
                    throw Shell.Failure(message: "swift test \(reason)")
                }
                let failures = Self.testFailures(in: output)
                guard !failures.isEmpty else {
                    let diagnostics = Self.compilerDiagnostics(output)
                    throw Shell.Failure(message: diagnostics.isEmpty ? (result.timedOut ? "timed out" : "exit \(result.status)") : diagnostics)
                }
                await waitForQuietLoad()
                let filters = failures.map { NSRegularExpression.escapedPattern(for: $0.name) }
                let rerun = try await testCommand(["swift", "test", "--filter", filters.joined(separator: "|")], source, MacCheck.home(home))
                let rerunOutput = [rerun.text, rerun.err].filter { !$0.isEmpty }.joined(separator: "\n")
                let stillFailing = Self.testFailures(in: rerunOutput)
                if rerun.status == 0 && !rerun.timedOut {
                    recordFlakyTests(failures, commit: commit)
                } else {
                    let named = stillFailing.isEmpty ? failures : stillFailing
                    fail(step, head: commit, detail: Self.failureDetails(named))
                    return
                }
            }
            step = "install"
            let tested = root.appending(path: "candidate")
            try? FileManager.default.removeItem(at: tested)
            try FileManager.default.copyItem(at: source.appending(path: ".build/release/oby-runner"), to: tested)
            candidate = tested
            ready = commit
            urgent = state.restarted.map(fixesFailure) ?? true
            status.phase = drainStarted == nil ? "ready" : "draining"
            deployIfReady()
        } catch {
            fail(step, head: head, detail: error.localizedDescription)
        }
    }

    /// Also ticked every second, so an idle runner doesn't wait another polling interval. A tested
    /// commit drains once `spacing` has passed since the last update's restart (or at once when it's
    /// `urgent`), and installs when the agents are idle or the drain limit passed, but only between
    /// the steps of a job's end of turn (`Desk.updateIsBetweenSteps`), never inside one.
    func deployIfReady() {
        guard status.phase == "ready" || status.phase == "draining", let candidate, let commit = ready else { return }
        if drainStarted == nil {
            if !urgent, let restarted = state.restarted, now().timeIntervalSince(restarted) < Self.spacing { return }
            desk.drainingForUpdate = true
            drainStarted = now()
            status.phase = "draining"
        }
        guard let drainStarted, desk.updateIsBetweenSteps,
              desk.updateIsIdle || now().timeIntervalSince(drainStarted) >= Self.drainLimit else { return }
        let previous = state
        do {
            state.installed = commit
            state.digest = try Self.digest(candidate)
            state.restarted = now()
            try save()
            try install(candidate, binary)
        } catch {
            state = previous
            // If installation failed, the old executable and its provenance are retained.
            try? save()
            return fail("install", head: commit)
        }
        status.phase = "restarting"
        // The jobs and the messages their agents were about to get are on disk: the new runner picks
        // them up, and this planned restart doesn't count towards a crash loop.
        desk.quit(planned: true)
        restart()
    }

    private func fail(_ step: String, head: String?, detail: String? = nil) {
        if let head { state.failed = head } else if state.outage == true { return } else { state.outage = true }
        try? save()
        if let ready, ready != head {
            // A newer commit failed: the tested one it was to replace still installs.
            status.waiting = ready
            status.phase = drainStarted == nil ? "ready" : "draining"
        } else {
            status.waiting = nil
            status.phase = "failed"
            candidate = nil
            ready = nil
            drainStarted = nil
            desk.cancelUpdateDrain()
        }
        // No build output is stored: it can contain credentials. A single durable item identifies
        // the step; polling/network failures are deduplicated too. Mark done after reading.
        let id = "runner-update-" + (head ?? "fetch-\(Int(now().timeIntervalSince1970))")
        // Try again (#215) tries the same commit again now; otherwise the next one is. Each try
        // that fails is its own item, counted in its id, so a retry's failure offers Try again
        // again; while one is open, the commit's next failure adds none.
        let tries = desk.inbox.filter { $0.id == id || $0.id.hasPrefix(id + "-try-") }
        guard !tries.contains(where: \.isOpen) else { return }
        let safeDetail = detail.map { desk.vault.redacting().redact(String($0.suffix(4000))) }
        desk.updateFailed(InboxItem(id: tries.isEmpty ? id : "\(id)-try-\(tries.count + 1)", kind: .failed, job: Desk.updateJob,
                                    title: "Runner update failed", text: "Runner update failed at \(step)\(head.map { " (\($0))" } ?? ""). The old binary is kept. \(head == nil ? "The next poll tries again." : "The next dev commit tries again.")\(safeDetail.map { "\n\($0)" } ?? "")",
                                    options: [Inbox.tryAgain], details: ["Builds and tests this commit again now, and installs it if it passes."], created: now()))
    }

    private func waitForQuietLoad() async {
        let deadline = now().addingTimeInterval(10 * 60)
        while loadAverage() >= Double(ProcessInfo.processInfo.activeProcessorCount), now() < deadline {
            await wait(.seconds(10))
        }
    }

    private func recordFlakyTests(_ failures: [TestFailure], commit: String) {
        let details = Self.failureDetails(failures)
        let clean = desk.vault.redacting().redact(details)
        let record = FailureRecord(id: "runner-update-\(commit)-flaky-test", trigger: .flakyTest, date: now(),
                                   job: Desk.updateJob, repo: Failures.repo, title: "Runner update flaky tests",
                                   what: "swift test failed once, then passed when the failing tests were rerun: \(clean)", rounds: nil,
                                   evidence: FailureRecord.Evidence(summary: "Runner update \(commit) installed after flaky tests passed on rerun.",
                                                                    step: "Runner update · swift test", check: clean))
        desk.failureLog.store.save(record)
    }

    private struct TestFailure {
        var name: String
        var message: String
    }

    private static func testFailures(in output: String) -> [TestFailure] {
        let lines = output.components(separatedBy: .newlines)
        var found: [TestFailure] = []
        var current: TestFailure?
        func flush() {
            if let current, !found.contains(where: { $0.name == current.name }) { found.append(current) }
        }
        for line in lines {
            if line.contains("✘ Test "), let range = line.range(of: "✘ Test ") {
                flush()
                let rest = line[range.upperBound...]
                let name = String(rest.split(whereSeparator: \.isWhitespace).prefix { $0 != "recorded" && $0 != "failed" }.joined(separator: " "))
                let message = line.range(of: ": ", options: .backwards).map { String(line[$0.upperBound...]) } ?? ""
                if !name.isEmpty { current = TestFailure(name: name, message: message) }
            } else if line.trimmingCharacters(in: .whitespaces).hasPrefix("↳"), current != nil {
                if var failure = current {
                    failure.message += (failure.message.isEmpty ? "" : "\n") + line.trimmingCharacters(in: .whitespaces)
                    current = failure
                }
            } else if line.contains("Test Case '") && line.contains("' failed") {
                flush()
                if let start = line.range(of: "Test Case '")?.upperBound,
                   let end = line[start...].range(of: "' failed")?.lowerBound {
                    current = TestFailure(name: String(line[start..<end]), message: line.trimmingCharacters(in: .whitespaces))
                    flush()
                    current = nil
                }
            }
        }
        flush()
        return found
    }

    private static func failureDetails(_ failures: [TestFailure]) -> String {
        failures.map { "\($0.name): \($0.message.isEmpty ? "failed" : $0.message)" }.joined(separator: "\n")
    }

    private static func compilerDiagnostics(_ output: String) -> String {
        output.components(separatedBy: .newlines)
            .filter { $0.contains("error:") || $0.contains("fatal error:") }
            .suffix(20).joined(separator: "\n")
    }

    /// Try again on a failed update's item: that commit is tried once more, now.
    @discardableResult
    func retry() -> Task<Void, Never> {
        if state.failed != nil {
            state.failed = nil
            try? save()
        }
        return Task { await poll() }
    }

    static func digest(_ file: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: file)).map { String(format: "%02x", $0) }.joined()
    }

    /// Rename a sibling file over the running executable: never truncate an executable in use.
    static func install(_ source: URL, _ target: URL) throws {
        let staged = target.deletingLastPathComponent().appending(path: ".oby-runner-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: staged) }
        try FileManager.default.copyItem(at: source, to: staged)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: staged.path)
        guard rename(staged.path, target.path) == 0 else {
            throw Shell.Failure(message: "Couldn't replace runner executable (errno \(errno)).")
        }
    }
}
