import Foundation

/// Runs the user's command-line tools (git, gh, claude) the way their terminal would.
nonisolated enum Shell {
    struct Output: Sendable {
        var status: Int32
        var out: Data
        var err: String
        /// It ran past its timeout and Oby ended it.
        var timedOut = false
        /// The process ended from an uncaught signal instead of returning an exit code.
        var terminatedBySignal = false
        var text: String { String(decoding: out, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Oby's own environment with PATH from the user's login shell, read once. The login shell
    /// comes from the user database: it can differ from $SHELL. Claude Code refuses to start
    /// inside another Claude session, so its variables never pass through.
    static let environment: [String: String] = {
        var env = ProcessInfo.processInfo.environment
        for key in env.keys where key == "CLAUDECODE" || key.hasPrefix("CLAUDE_CODE_") || key.hasPrefix("ANTHROPIC_") {
            env[key] = nil
        }
        // Cursor's own logins: a key or token in an agent's environment would be a login its
        // subprocesses see (Cursor jobs sign in through their account home).
        for key in ["CURSOR_API_KEY", "CURSOR_AUTH_TOKEN"] { env[key] = nil }
        // The GitHub app's settings stay with the runner: nothing it runs needs where the key is.
        for key in GitHubApp.variables { env[key] = nil }
        if let user = getpwuid(getuid()), let shell = user.pointee.pw_shell {
            let process = Process()
            let out = Pipe()
            process.executableURL = URL(filePath: String(cString: shell))
            process.arguments = ["-l", "-c", "/usr/bin/env"]
            process.standardOutput = out
            process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice
            if (try? process.run()) != nil {
                let lines = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).split(separator: "\n")
                process.waitUntilExit()
                if let path = lines.first(where: { $0.hasPrefix("PATH=") }) { env["PATH"] = String(path.dropFirst(5)) }
            }
        }
        return env
    }()

    /// Runs a tool found on the user's PATH. `env` adds variables, and a nil value removes one.
    /// After `timeout` seconds it's ended, with all it started (`Halt`), and so it is when the task
    /// is cancelled. A gh call `as: .app` gets the GitHub app's installation token for the account
    /// it names (`GitHubApp.account(in:)`) in `GH_TOKEN`, and once more a fresh one when GitHub
    /// refuses it; with no app, no installation for that account, or a call about the owner
    /// (`GitHubApp.ownersOwn`), it runs with the owner's gh login, as every other call does.
    static func run(_ arguments: [String], in directory: URL? = nil, input: Data? = nil,
                    env: [String: String?] = [:], timeout: TimeInterval = 600, as actor: GitHubActor = .owner) async throws -> Output {
        guard actor == .app, let app = stand?.app ?? GitHubApp.shared, !GitHubApp.ownersOwn(arguments),
              let token = await app.token(for: GitHubApp.account(in: arguments)) else {
            return try await launch(arguments, in: directory, input: input, env: env, timeout: timeout)
        }
        var appEnv = env
        appEnv["GITHUB_TOKEN"] = .some(nil)
        appEnv["GH_TOKEN"] = token
        let result = try await launch(arguments, in: directory, input: input, env: appEnv, timeout: timeout)
        guard GitHubApp.refused(result) else { return result }
        await app.refused(token)
        guard let fresh = await app.token(for: GitHubApp.account(in: arguments)) else {
            return try await launch(arguments, in: directory, input: input, env: env, timeout: timeout)
        }
        appEnv["GH_TOKEN"] = fresh
        return try await launch(arguments, in: directory, input: input, env: appEnv, timeout: timeout)
    }

    /// What a test stands in with, for its own task only: the GitHub app, and the tools, which get
    /// the arguments and the variables `env` adds.
    struct Stand: Sendable {
        var app: GitHubApp?
        var run: @Sendable (_ arguments: [String], _ env: [String: String?]) async throws -> Output
    }
    @TaskLocal static var stand: Stand?
    /// The directory and stdin of the run a stand plays, for a stand-in tool that reads them
    /// (a fake `claude` reading its quoted file).
    struct Call: Sendable {
        var directory: URL?
        var input: Data?
    }
    @TaskLocal static var call: Call?

    private static func launch(_ arguments: [String], in directory: URL?, input: Data?,
                               env: [String: String?], timeout: TimeInterval) async throws -> Output {
        if let stand {
            return try await $call.withValue(Call(directory: directory, input: input)) { try await stand.run(arguments, env) }
        }
        let running = Running()
        return try await withTaskCancellationHandler {
            try await run(arguments, in: directory, input: input, env: env, timeout: timeout, running: running)
        } onCancel: {
            running.cancel()
        }
    }

    private static func run(_ arguments: [String], in directory: URL?, input: Data?, env: [String: String?],
                            timeout: TimeInterval, running: Running) async throws -> Output {
        try await withCheckedThrowingContinuation { done in
            // Threads of its own, not Dispatch's: this blocks until the tool ends, and with many
            // running at once (a busy Mac's `swift test`) Dispatch's workers ran out, and a run waited
            // half a minute for one, its stderr reader too.
            Thread.detachNewThread {
                let process = Process()
                let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
                process.executableURL = URL(filePath: "/usr/bin/env")
                process.arguments = arguments
                process.currentDirectoryURL = directory
                var environment = Self.environment
                for (key, value) in env { environment[key] = value }
                process.environment = environment
                process.standardInput = stdin
                process.standardOutput = stdout
                process.standardError = stderr
                // What it leaves running ends with it, so its output ends too (a check's test can't hold it).
                let group: ProcessGroup
                do { group = try ProcessGroup.run(process) } catch { done.resume(throwing: error); return }
                running.started(group)

                let deadline = Deadline()
                deadline.schedule(timeout) { group.end(after: Halt.dropping) }
                // Read stderr on its own thread so a chatty tool can't fill the pipe and stall.
                let err = Collected()
                let reading = DispatchGroup()
                reading.enter()
                Thread.detachNewThread {
                    err.data = stderr.fileHandleForReading.readDataToEndOfFile()
                    reading.leave()
                }
                if let input { try? stdin.fileHandleForWriting.write(contentsOf: input) }
                try? stdin.fileHandleForWriting.close()
                let out = stdout.fileHandleForReading.readDataToEndOfFile()
                reading.wait()
                process.waitUntilExit()
                let timedOut = deadline.finish()
                done.resume(returning: Output(status: process.terminationStatus, out: out, err: String(decoding: err.data, as: UTF8.self),
                                              timedOut: timedOut,
                                              terminatedBySignal: process.terminationReason == .uncaughtSignal))
            }
        }
    }

    /// Runs a tool and returns its output, or throws with the last thing it said on stderr.
    @discardableResult
    static func ok(_ arguments: [String], in directory: URL? = nil, env: [String: String?] = [:],
                   as actor: GitHubActor = .owner) async throws -> String {
        let result = try await run(arguments, in: directory, env: env, as: actor)
        guard result.status == 0 else {
            // gh project puts the missing-scopes diagnostic before its final refresh hint.
            let project = Array(arguments.prefix(2)) == ["gh", "project"]
            let full = [result.text, result.err].filter { !$0.isEmpty }.joined(separator: "\n")
            let said = project && !full.isEmpty ? full : result.err.split(separator: "\n").last.map(String.init) ?? "exit \(result.status)"
            throw Failure(message: "\(arguments.prefix(2).joined(separator: " ")): \(said)")
        }
        return result.text
    }

    private final class Collected: @unchecked Sendable { var data = Data() }

    /// A process timeout uses its own sleeping thread so a saturated Dispatch worker pool cannot
    /// delay ending the command. Finishing the process wakes that thread instead of leaving it
    /// around until the original timeout expires.
    private final class Deadline: @unchecked Sendable {
        private let condition = NSCondition()
        private var finished = false
        private var expired = false

        func schedule(_ seconds: TimeInterval, onTimeout: @escaping @Sendable () -> Void) {
            Thread.detachNewThread { [self] in
                condition.lock()
                let timedOut = !finished && !condition.wait(until: Date.now.addingTimeInterval(seconds)) && !finished
                if timedOut { expired = true; finished = true }
                condition.unlock()
                if timedOut { onTimeout() }
            }
        }

        func finish() -> Bool {
            condition.lock()
            finished = true
            condition.broadcast()
            let timedOut = expired
            condition.unlock()
            return timedOut
        }
    }

    /// The process group a run started, for cancelling it: whichever comes second, the start or
    /// the cancel, ends it.
    private final class Running: @unchecked Sendable {
        private let lock = NSLock()
        private var group: ProcessGroup?
        private var cancelled = false

        func started(_ group: ProcessGroup) {
            lock.withLock {
                self.group = group
                if cancelled { group.end(after: Halt.dropping) }
            }
        }

        func cancel() {
            lock.withLock {
                cancelled = true
                group?.end(after: Halt.dropping)
            }
        }
    }
}
