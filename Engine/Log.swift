#if !canImport(OSLog)
import Foundation

/// OSLog's `Logger` where there is no OSLog (the runner on Linux): one line per message on
/// stderr, which systemd keeps in the journal. Values not marked public are left out, as in OSLog.
nonisolated struct Logger: Sendable {
    let category: String

    init(subsystem: String, category: String) { self.category = category }

    func notice(_ message: Message) { write("notice", message) }
    func error(_ message: Message) { write("error", message) }

    private func write(_ level: String, _ message: Message) {
        FileHandle.standardError.write(Data("\(level) [\(category)] \(message.text)\n".utf8))
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
