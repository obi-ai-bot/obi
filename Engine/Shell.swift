import Foundation

/// Runs the user's command-line tools (git, gh, claude) the way their terminal would.
nonisolated enum Shell {
    struct Output: Sendable {
        var status: Int32
        var out: Data
        var err: String
        /// It ran past its timeout and Oby ended it.
        var timedOut = false
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
    /// Cancelling the task ends the tool, with the tools it started.
    static func run(_ arguments: [String], in directory: URL? = nil, input: Data? = nil,
                    env: [String: String?] = [:], timeout: TimeInterval = 600) async throws -> Output {
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
            DispatchQueue.global().async {
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
                do { try process.run() } catch { done.resume(throwing: error); return }
                running.started(process)

                // Past the timeout, the whole process group ends, so a tool it started can't hold the pipes open.
                let expired = Collected()
                let kill = DispatchWorkItem { expired.data = Data([1]); Halt.end(process) }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: kill)
                // Read stderr on its own thread so a chatty tool can't fill the pipe and stall.
                let err = Collected()
                let reading = DispatchGroup()
                DispatchQueue.global().async(group: reading) { err.data = stderr.fileHandleForReading.readDataToEndOfFile() }
                if let input { try? stdin.fileHandleForWriting.write(contentsOf: input) }
                try? stdin.fileHandleForWriting.close()
                let out = stdout.fileHandleForReading.readDataToEndOfFile()
                reading.wait()
                process.waitUntilExit()
                kill.cancel()
                done.resume(returning: Output(status: process.terminationStatus, out: out, err: String(decoding: err.data, as: UTF8.self),
                                              timedOut: !expired.data.isEmpty))
            }
        }
    }

    /// Runs a tool and returns its output, or throws with the last thing it said on stderr.
    @discardableResult
    static func ok(_ arguments: [String], in directory: URL? = nil, env: [String: String?] = [:]) async throws -> String {
        let result = try await run(arguments, in: directory, env: env)
        guard result.status == 0 else {
            let said = result.err.split(separator: "\n").last.map(String.init) ?? "exit \(result.status)"
            throw Failure(message: "\(arguments.prefix(2).joined(separator: " ")): \(said)")
        }
        return result.text
    }

    private final class Collected: @unchecked Sendable { var data = Data() }

    /// The process a run started, for cancelling it: whichever comes second, the start or the
    /// cancel, ends it.
    private final class Running: @unchecked Sendable {
        private let lock = NSLock()
        private var process: Process?
        private var cancelled = false

        func started(_ process: Process) {
            lock.withLock {
                self.process = process
                if cancelled { Halt.end(process) }
            }
        }

        func cancel() {
            lock.withLock {
                cancelled = true
                if let process { Halt.end(process) }
            }
        }
    }
}
