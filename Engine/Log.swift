import Foundation
#if canImport(OSLog)
import os
#endif

/// Oby's logger, in place of OSLog's `Logger` (this module's type wins over the import): OSLog on
/// the Mac, one line per message on stderr on the runner, which systemd keeps in the journal.
/// Values not marked public are left out, as in OSLog, and the vault's secrets, plain or encoded,
/// are taken out of the rest before anything is written, on either.
nonisolated struct Logger: Sendable {
    let category: String
    #if canImport(OSLog)
    private let system: os.Logger
    #endif

    init(subsystem: String, category: String) {
        self.category = category
        #if canImport(OSLog)
        system = os.Logger(subsystem: subsystem, category: category)
        #endif
    }

    func notice(_ message: Message) { write("notice", message) }
    func error(_ message: Message) { write("error", message) }
    func debug(_ message: Message) { write("debug", message) }

    private func write(_ level: String, _ message: Message) {
        #if canImport(OSLog)
        // Redacted already: what's left may show.
        let said = text(message)
        switch level {
        case "error": system.error("\(said, privacy: .public)")
        case "debug": system.debug("\(said, privacy: .public)")
        default: system.notice("\(said, privacy: .public)")
        }
        #else
        FileHandle.standardError.write(Data(line(level, message).utf8))
        #endif
    }

    /// What's written: the message with the vault's secrets taken out, as the vault is now, or the
    /// latest values known when it can't be read.
    func text(_ message: Message, vault: Vault = .shared) -> String {
        vault.redacting().redact(message.text)
    }

    /// The runner's line: level, category, and `text`.
    func line(_ level: String, _ message: Message, vault: Vault = .shared) -> String {
        "\(level) [\(category)] \(text(message, vault: vault))\n"
    }

    enum Privacy { case `public`, `private` }

    struct Message: ExpressibleByStringInterpolation {
        var text: String

        init(stringLiteral value: String) { text = value }
        init(stringInterpolation: Interpolation) { text = stringInterpolation.text }

        struct Interpolation: StringInterpolationProtocol {
            var text = ""

            init(literalCapacity: Int, interpolationCount: Int) {}
            mutating func appendLiteral(_ literal: String) { text += literal }
            mutating func appendInterpolation(_ value: some CustomStringConvertible, privacy: Privacy = .private) {
                text += privacy == .public ? value.description : "<private>"
            }
        }
    }
}
