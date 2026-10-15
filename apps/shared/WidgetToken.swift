import Foundation

/// The Watch complications' WidgetKit push token on its way to the runner (docs/runner-api.md,
/// `POST /v1/notifications` on the Watch API). WidgetKit can issue or rotate the token at any
/// time, also long after the app last ran, so the widget uploads a new one itself, and the app
/// tries again whenever it runs, until the runner has accepted the latest token. Foundation only:
/// the runner's tests cover it.
nonisolated struct WidgetToken: Codable, Equatable, Sendable {
    /// The latest token WidgetKit issued.
    var issued: Data?
    /// The latest token the runner accepted.
    var accepted: Data?

    /// The token still to upload: the latest one, until the runner accepts it.
    var pending: Data? { issued == accepted ? nil : issued }

    /// Uploads the pending token until the runner accepts it, up to `attempts` tries with `wait`
    /// between them (given how many failed so far). The token is read again before every try, so
    /// one rotated meanwhile goes too; `accept` records each token the runner took. Answers whether
    /// nothing is pending at the end.
    static func deliver(attempts: Int, current: () -> WidgetToken, accept: (Data) -> Void,
                        send: (Data) async throws -> Void, wait: (Int) async -> Void) async -> Bool {
        var failures = 0
        while failures < attempts {
            guard let token = current().pending else { return true }
            do {
                try await send(token)
                accept(token)
            } catch {
                failures += 1
                if failures < attempts { await wait(failures) }
            }
        }
        return current().pending == nil
    }

    /// Records that the runner accepted `token`.
    mutating func accept(_ token: Data) {
        accepted = token
    }
}
