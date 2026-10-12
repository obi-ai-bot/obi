import Foundation
import Crypto
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
            throw Shell.Failure(message: result.timedOut ? "timed out" : "exit \(result.status)")
        }
        return result.text
    }
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
            step = "swift test"
            // Like a Mac check, the tests' Obys get a throwaway home, never the runner's own data.
            let home = FileManager.default.temporaryDirectory.appending(path: "oby-update-home-\(commit.prefix(12))")
            try? FileManager.default.removeItem(at: home)
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: home) }
            _ = try await command(["swift", "test"], source, MacCheck.home(home))
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
            fail(step, head: head)
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

    private func fail(_ step: String, head: String?) {
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
        let id = head ?? "fetch-\(Int(now().timeIntervalSince1970))"
        // Try again (#215) tries the same commit again now; otherwise the next one is.
        desk.updateFailed(InboxItem(id: "runner-update-\(id)", kind: .failed, job: Desk.updateJob,
                                    title: "Runner update failed", text: "Runner update failed at \(step)\(head.map { " (\($0))" } ?? ""). The old binary is kept. \(head == nil ? "The next poll tries again." : "The next dev commit tries again.")",
                                    options: [Inbox.tryAgain], created: now()))
    }

    /// Try again on a failed update's item: that commit is tried once more, now.
    func retry() {
        if state.failed != nil {
            state.failed = nil
            try? save()
        }
        Task { await poll() }
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
