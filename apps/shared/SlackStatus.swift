import Foundation

/// Slack, connected once on obid (docs/runner-api.md, "obid only: Slack") with the owner's own
/// Slack app: its user token (searching) and bot token (the DM to the owner), pasted once here and
/// kept in obid's vault. The Mac only learns whether they work and for which workspace; it never
/// keeps them.
nonisolated struct SlackStatus: Decodable, Equatable, Sendable {
    /// What it does, as Sangam's Connectors says it.
    static let about = "Read and send messages"

    var connected = false
    /// The workspace's name.
    var team: String?
    /// Why obid was signed out, in its words, or nil.
    var error: String?

    private enum Keys: String, CodingKey { case connected, team, error }

    init(connected: Bool = false, team: String? = nil, error: String? = nil) {
        (self.connected, self.team, self.error) = (connected, team, error)
    }

    init(from decoder: any Decoder) throws {
        let keys = try decoder.container(keyedBy: Keys.self)
        connected = (try? keys.decodeIfPresent(Bool.self, forKey: .connected)) ?? false
        team = try? keys.decodeIfPresent(String.self, forKey: .team)
        error = try? keys.decodeIfPresent(String.self, forKey: .error)
    }

    /// The row's tooltip: how it's connected, or what connecting takes.
    var how: String {
        if connected { return "Connected to \(team ?? "your workspace") with your Slack app's tokens. Oby reads messages for the watcher and writes only to you." }
        return error ?? "You paste your Slack app's two tokens once (OAuth & Permissions › OAuth Tokens). obid keeps them in its vault."
    }

    /// Whether `text` looks like a token of this kind (`xoxp-` or `xoxb-`), as obid takes it.
    static func isToken(_ text: String, _ prefix: String) -> Bool {
        let token = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return token.hasPrefix(prefix) && (20...512).contains(token.count) && token.allSatisfy { $0.isASCII && !$0.isWhitespace }
    }
}

/// The watcher's rules as Settings needs them (`GET /v1/watch`): its name, and whether it sends the
/// Slack message or only writes it down (a dry run).
nonisolated struct WatchStatus: Decodable, Equatable, Sendable {
    struct Rules: Decodable, Equatable, Sendable {
        var name: String
        var live: Bool
        var enabled: Bool
    }
    var rules: Rules?

    /// "Dmitry watcher: a dry run, it tells you in Oby and only writes down the Slack message."
    var line: String? {
        guard let rules else { return nil }
        if !rules.enabled { return "\(rules.name): paused." }
        return rules.live ? "\(rules.name): tells you in Oby and in a Slack message to yourself."
                          : "\(rules.name): a dry run, it tells you in Oby and only writes down the Slack message."
    }
}

/// A `watch` inbox item (obid only: the watcher), as the Mac's notification shows it. Engine's inbox
/// doesn't know the kind; obid's own words only (`title`, `text`), never what was written.
nonisolated struct WatchNotice: Decodable, Equatable, Sendable {
    var kind: String
    var id: String
    var title: String
    var text: String
    var created: Date
    var done: Date?
}

#if os(macOS)
extension Runner {
    /// obid's Slack, or nil from a runner that doesn't hold one (404).
    func slack() async throws -> SlackStatus? {
        do {
            return try await call("GET", "v1/slack")
        } catch let error as RunnerError where error.status == 404 {
            return nil
        }
    }

    /// Gives obid the Slack app's tokens: it checks them with Slack and keeps them in its vault. The
    /// app-level token (`app`) is for the channel listener's Socket Mode; nil leaves it out.
    func connectSlack(user: String, bot: String, app: String?) async throws -> SlackStatus {
        struct Body: Encodable { var user: String; var bot: String; var app: String? }
        return try await call("PUT", "v1/slack", body: Body(user: user, bot: bot, app: app))
    }

    /// obid forgets the Slack tokens: the watcher reads only GitHub until they're pasted again.
    func disconnectSlack() async throws {
        try await send("DELETE", "v1/slack")
    }

    /// The watcher, or nil from a runner that has none to say (404).
    func watch() async throws -> WatchStatus? {
        do {
            return try await call("GET", "v1/watch")
        } catch let error as RunnerError where error.status == 404 {
            return nil
        }
    }

    /// Turns the watcher's Slack message to the owner on (`live`) or back to a dry run.
    func setWatchLive(_ live: Bool) async throws -> WatchStatus {
        struct Body: Encodable { var live: Bool }
        return try await call("PATCH", "v1/watch", body: Body(live: live))
    }
}
#endif
