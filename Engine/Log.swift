#if !canImport(OSLog)
import Foundation

/// OSLog's `Logger` where there is no OSLog (the runner on Linux): one line per message on
/// stderr, which systemd keeps in the journal. Values not marked public are left out, as in OSLog,
/// and the vault's secrets, plain or encoded, are taken out of the rest.
nonisolated struct Logger: Sendable {
    let category: String

    init(subsystem: String, category: String) { self.category = category }

    func notice(_ message: Message) { write("notice", message) }
    func error(_ message: Message) { write("error", message) }

    private func write(_ level: String, _ message: Message) {
        FileHandle.standardError.write(Data(line(level, message).utf8))
    }

    /// The line `write` puts out, with the vault's secrets taken out: as the vault is now, or the
    /// latest values known when it can't be read.
    func line(_ level: String, _ message: Message, vault: Vault = .shared) -> String {
        "\(level) [\(category)] \(vault.redacting().redact(message.text))\n"
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
#endif
