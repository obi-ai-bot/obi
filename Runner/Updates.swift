import Foundation
import Crypto
@testable import ObyEngine

/// Owns a checkout outside every agent sandbox. A failed commit is tried once, even across
/// restarts; deployment and recovery are journaled before the installed executable changes.
@MainActor
final class Updates {
    static let interval: TimeInterval = 180
    static let drainLimit: TimeInterval = 30 * 60

    struct State: Codable {
        var attempted: String?
        var installed: String?
        var digest: String?
        var resume: [String] = []
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
    private var candidate: URL?
    var now: () -> Date = Date.init
    /// Fake commands and install/restart in tests. Production commands never enter Agents.sandboxed.
    var command: ([String], URL) async throws -> String = { args, directory in
        let result = try await Shell.run(args, in: directory, timeout: 1800)
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
        state = (try? JSONDecoder().decode(State.self, from: Data(contentsOf: root.appending(path: "state.json")))) ?? State()
        // A manual install must not report the previous executable's commit.
        let commit = state.digest == (try? Self.digest(binary)) ? state.installed : nil
        status = Status(commit: commit, waiting: nil, phase: "idle")
    }

    static func recoveryIDs(root: URL = Workspace.root.appending(path: "updates")) -> Set<String> {
        guard let data = try? Data(contentsOf: root.appending(path: "state.json")),
              let state = try? JSONDecoder().decode(State.self, from: data) else { return [] }
        return Set(state.resume)
    }

    private func save() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode(state).write(to: root.appending(path: "state.json"), options: .atomic)
    }

    /// Called before polling/accounts refresh. Jobs with questions still wait for their answer.
    func recover() throws {
        guard !state.resume.isEmpty else { return }
        desk.resumeAfterUpdate(state.resume)
        state.resume = []
        try save()
    }

    func poll() async {
        guard !polling else { return }
        polling = true
        defer { polling = false }
        if candidate != nil { return deployIfReady() }
        var step = "fetch dev"
        var head: String?
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let source = root.appending(path: "source")
            if !FileManager.default.fileExists(atPath: source.appending(path: ".git").path) {
                _ = try await command(["git", "clone", "--single-branch", "--branch", "dev",
                                       "https://github.com/deskree-inc/oby.git", source.path], root)
            }
            _ = try await command(["git", "fetch", "origin", "dev"], source)
            let commit = try await command(["git", "rev-parse", "refs/remotes/origin/dev"], source)
            guard commit != status.commit, commit != state.attempted else { return }
            head = commit
            state.attempted = commit
            try save()
            status.waiting = commit
            status.phase = "building"
            step = "checkout dev"
            _ = try await command(["git", "reset", "--hard", commit], source)
            _ = try await command(["git", "clean", "-fd"], source)
            step = "swift build -c release"
            _ = try await command(["swift", "build", "-c", "release"], source)
            step = "swift test"
            _ = try await command(["swift", "test"], source)
            candidate = source.appending(path: ".build/release/oby-runner")
            desk.drainingForUpdate = true
            drainStarted = now()
            status.phase = "draining"
            deployIfReady()
        } catch {
            fail(step, head: head)
        }
    }

    /// Also ticked every second, so an idle runner doesn't wait another polling interval.
    func deployIfReady() {
        guard status.phase == "draining", let candidate, let commit = status.waiting, let drainStarted,
              desk.updateIsIdle || now().timeIntervalSince(drainStarted) >= Self.drainLimit else { return }
        let previous = state
        do {
            state.resume = desk.active.map(\.id)
            state.installed = commit
            state.digest = try Self.digest(candidate)
            try save()
            try install(candidate, binary)
        } catch {
            state = previous
            // If installation failed, the old executable and its provenance are retained.
            try? save()
            return fail("install", head: commit)
        }
        status.phase = "restarting"
        desk.quit()
        restart()
    }

    private func fail(_ step: String, head: String?) {
        status.waiting = nil
        status.phase = "failed"
        candidate = nil
        drainStarted = nil
        desk.cancelUpdateDrain()
        // No build output is stored: it can contain credentials. A single durable item identifies
        // the step; polling/network failures are deduplicated too. Mark done after reading.
        desk.updateFailed(InboxItem(id: "runner-update-\(head ?? "fetch")", kind: .failed, job: "runner-update",
                                    title: "Runner update failed", text: "Runner update failed at \(step)\(head.map { " (\($0))" } ?? ""). The old binary is kept. \(head == nil ? "The next poll tries again." : "The next dev commit tries again.")",
                                    options: [], created: now()))
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
