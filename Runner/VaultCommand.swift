import Foundation
@testable import ObyEngine

/// `oby-runner vault list | add NAME | remove NAME`, run as the runner's user with its `OBY_HOME`:
/// the runner's vault from a terminal on the machine. A value comes in on stdin, never as an
/// argument (other users see those in `ps`), and nothing this prints holds one.
enum VaultCommand {
    static let usage = "usage: oby-runner vault list | add NAME (the value on stdin) | remove NAME"

    /// Runs `arguments` (what follows `vault`) and returns the exit status. `read` gives the value
    /// for `add`; `say` and `fail` print to stdout and stderr.
    static func run(_ arguments: [String], vault: Vault = .shared, read: () -> String? = readValue,
                    say: (String) -> Void = { print($0) }, fail: (String) -> Void = complain) -> Int32 {
        do {
            switch (arguments.first, arguments.count) {
            case ("list", 1):
                try vault.names().forEach(say)
            case ("add", 2):
                guard let value = read() else { fail("No value on stdin."); return 1 }
                try vault.add(value, as: arguments[1])
                say("Saved \(arguments[1]).")
            case ("remove", 2):
                try vault.remove(arguments[1])
                say("Removed \(arguments[1]).")
            default:
                fail(usage)
                return 2
            }
            return 0
        } catch {
            fail(error.localizedDescription)
            return 1
        }
    }

    /// The value from stdin: typed without echo at a terminal, else everything piped in.
    static func readValue() -> String? {
        guard isatty(STDIN_FILENO) == 1 else {
            let data = FileHandle.standardInput.readDataToEndOfFile()
            return data.isEmpty ? nil : String(decoding: data, as: UTF8.self)
        }
        complain("Value (not shown), then Return:")
        var saved = termios()
        tcgetattr(STDIN_FILENO, &saved)
        var quiet = saved
        quiet.c_lflag &= ~tcflag_t(ECHO)
        tcsetattr(STDIN_FILENO, TCSANOW, &quiet)
        defer {
            tcsetattr(STDIN_FILENO, TCSANOW, &saved)
            complain("")
        }
        return readLine(strippingNewline: true)
    }

    static func complain(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }
}
