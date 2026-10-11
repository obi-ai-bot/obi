import Foundation
@testable import ObyEngine

/// When the user last pressed Clear done, on the iPhone or the Mac (`POST /v1/clear`). Both apps
/// hide the jobs that finished by then, so clearing on one clears on both; the runner keeps every
/// job. Kept in `cleared.json` so a restart remembers it; nil until the first clear. With no file
/// (the tests) it lives in memory only.
@MainActor
final class Cleared {
    private struct Saved: Codable {
        var clearedAt: Date
    }

    private let file: URL?
    /// The runner's clock when Clear done was last pressed, or nil: nothing is cleared.
    private(set) var at: Date?

    init(file: URL?) {
        self.file = file
        guard let file, let data = try? Data(contentsOf: file) else { return }
        do {
            at = try Self.decoder.decode(Saved.self, from: data).clearedAt
        } catch {
            Logger.runner.error("can't read \(file.path, privacy: .public): nothing counts as cleared until the next Clear done")
        }
    }

    /// Records `now` as the last clear and returns it. The clock never goes back: a clear earlier
    /// than the last one (a clock that was put right) keeps the later time.
    @discardableResult
    func clear(now: Date = .now) throws -> Date {
        let time = max(now, at ?? .distantPast)
        at = time
        if let file {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(Saved(clearedAt: time)).write(to: file, options: .atomic)
        }
        return time
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
