import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// `oby-check apple` (the script runs `oby-runner check apple`): what an agent runs in its sandbox
/// to have the user's Mac build and test the Apple apps at its worktree's commit
/// (Engine/AppleChecks.swift). It asks the runner on `OBY_CHECK_URL` with its job's
/// `OBY_CHECK_TOKEN`, then waits, saying where the check is, up to `--wait` seconds in all,
/// requests to the runner included: 110 by default, under a 2-minute command timeout, or
/// `OBY_CHECK_WAIT` when a job's final check runs it (#68). Asking again picks up the same check.
/// In a job's final check run again without the Apple build (`AppleCheck.skipVariable`), it says so
/// and exits 0.
/// Exits 0 when everything passed, 1 when something failed, 2 when the check couldn't run (no Mac
/// took it, the Mac couldn't, no runner), 3 when it's still running, 64 for a wrong command line.
enum CheckCommand {
    /// One request to the runner: the method and path, and what it answered.
    typealias Send = @Sendable (_ method: String, _ path: String) async throws -> (status: Int, body: Data)
    /// Waits `seconds`, then returns: the end of a request's time.
    typealias Timer = @Sendable (_ seconds: TimeInterval) async throws -> Void

    static let usage = "usage: oby-check apple [--wait SECONDS]"
    static let skipLine = "No Mac took the Apple check, so Oby runs the job's check again without it: the Apple apps aren't built here, and the rest of the check decides."
    static let defaultWait = 110
    static let maxWait = 3000
    /// How often it asks where the check is, in seconds.
    static let interval = 5
    static let path = "/v1/agent/apple-check"

    /// What the runner answers (`AppleCheckAnswer` in Runner/API.swift).
    struct Answer: Decodable {
        struct Check: Decodable {
            var id: String
            var state: String
        }
        var check: Check
        var line: String
        var report: String?
    }

    struct Failure: Error {
        var message: String
    }

    /// `now` and `sleep` are the clock it waits by, and `timer` ends a request the runner doesn't
    /// answer in the time left. Tests put in their own: a timer on the real clock would end a
    /// request against a test's own clock.
    static func run(_ arguments: [String], environment: [String: String] = ProcessInfo.processInfo.environment, send: Send? = nil,
                    now: () -> Date = { Date.now },
                    sleep: (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) },
                    timer: @escaping Timer = { try await Task.sleep(for: .seconds($0)) },
                    uncommitted: () async -> Bool = { CheckCommand.uncommitted() },
                    print out: (String) -> Void = { Swift.print($0) }) async -> Int32 {
        guard let wait = Self.wait(arguments, default: environment["OBY_CHECK_WAIT"].flatMap { Int($0) }) else {
            out(usage)
            return 64
        }
        if environment["OBY_CHECK_SKIP"] == "1" {
            out(skipLine)
            return 0
        }
        guard let url = environment["OBY_CHECK_URL"], let token = environment["OBY_CHECK_TOKEN"], !url.isEmpty, !token.isEmpty else {
            out("oby-check works only inside an Oby job on the runner: there's no runner to ask here.")
            return 2
        }
        let send = send ?? http(url, token: token)
        let start = now()
        let deadline = start.addingTimeInterval(TimeInterval(wait))
        func left() -> TimeInterval { deadline.timeIntervalSince(now()) }
        if await uncommitted() {
            out("Your uncommitted changes aren't in the check: the Mac builds your last commit. Commit them and run oby-check apple again to check them.")
        }
        var answer: Answer
        do {
            guard let first = try await call(send, "POST", within: left(), timer: timer) else {
                out("The runner didn't answer within \(wait) seconds.")
                return 2
            }
            answer = first
        } catch {
            out((error as? Failure)?.message ?? "The runner didn't answer: \(error.localizedDescription)")
            return 2
        }
        out(answer.line)
        /// Out of time with the check under way: how to keep waiting.
        func still(_ answer: Answer) -> Int32 {
            out("Still \(answer.check.state) after \(Int(now().timeIntervalSince(start).rounded())) seconds. Run oby-check apple again to keep waiting: it picks up the same check.")
            return 3
        }
        var said = answer.line
        while answer.report == nil {
            guard left() > 0 else { return still(answer) }
            try? await sleep(min(TimeInterval(interval), left()))
            do {
                guard left() > 0, let next = try await call(send, "GET", within: left(), timer: timer) else { return still(answer) }
                answer = next
            } catch {
                out((error as? Failure)?.message ?? "The runner didn't answer: \(error.localizedDescription)")
                return 2
            }
            if answer.line != said {
                out(answer.line)
                said = answer.line
            }
        }
        out(answer.report ?? "")
        switch answer.check.state {
        case "passed": return 0
        case "failed": return 1
        default: return 2
        }
    }

    /// How long to wait, from the command line, or nil when it isn't `apple [--wait SECONDS]`.
    /// Without `--wait`, `default` (from `OBY_CHECK_WAIT`), within 1 to `maxWait`, or `defaultWait`.
    static func wait(_ arguments: [String], default given: Int? = nil) -> Int? {
        guard arguments.first == "apple" else { return nil }
        switch arguments.count {
        case 1: return given.map { min(max($0, 1), maxWait) } ?? defaultWait
        case 3 where arguments[1] == "--wait": return Int(arguments[2]).flatMap { (1...maxWait).contains($0) ? $0 : nil }
        default: return nil
        }
    }

    /// One request, given at most `seconds` by `timer`: nil when the runner didn't answer in time.
    static func call(_ send: @escaping Send, _ method: String, within seconds: TimeInterval,
                     timer: @escaping Timer = { try await Task.sleep(for: .seconds($0)) }) async throws -> Answer? {
        let answered = try await withThrowingTaskGroup(of: (status: Int, body: Data)?.self) { group in
            group.addTask { try await send(method, path) }
            group.addTask {
                try await timer(max(0, seconds))
                return nil
            }
            defer { group.cancelAll() }
            return try await group.next() ?? nil
        }
        guard let (status, body) = answered else { return nil }
        guard (200..<300).contains(status) else {
            struct Problem: Decodable { var error: String }
            throw Failure(message: (try? JSONDecoder().decode(Problem.self, from: body))?.error ?? "The runner answered \(status).")
        }
        do {
            return try JSONDecoder().decode(Answer.self, from: body)
        } catch {
            throw Failure(message: "The runner said something oby-check doesn't understand.")
        }
    }

    /// Requests to the runner's API on this machine, with the job's token.
    static func http(_ base: String, token: String) -> Send {
        { method, path in
            guard let url = URL(string: base + path) else { throw Failure(message: "OBY_CHECK_URL isn't a URL.") }
            var request = URLRequest(url: url)
            request.httpMethod = method
            request.timeoutInterval = 60
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let (data, response) = try await URLSession.shared.data(for: request)
            return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
        }
    }

    /// Whether the worktree here has changes its last commit doesn't.
    static func uncommitted() -> Bool {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/env")
        process.arguments = ["git", "status", "--porcelain"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 && !data.isEmpty
    }
}
