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
    /// Whether obid holds the app-level token the channel listener's Socket Mode needs.
    var socket = false
    /// Why obid was signed out, in its words, or nil.
    var error: String?
    /// Whether a posted review's author is told on Slack, as the owner (on unless turned off).
    var tellAuthors = false

    private enum Keys: String, CodingKey { case connected, team, socket, error, tellAuthors }

    init(connected: Bool = false, team: String? = nil, socket: Bool = false, error: String? = nil, tellAuthors: Bool = false) {
        (self.connected, self.team, self.socket, self.error, self.tellAuthors) = (connected, team, socket, error, tellAuthors)
    }

    init(from decoder: any Decoder) throws {
        let keys = try decoder.container(keyedBy: Keys.self)
        connected = (try? keys.decodeIfPresent(Bool.self, forKey: .connected)) ?? false
        team = try? keys.decodeIfPresent(String.self, forKey: .team)
        socket = (try? keys.decodeIfPresent(Bool.self, forKey: .socket)) ?? false
        error = try? keys.decodeIfPresent(String.self, forKey: .error)
        tellAuthors = (try? keys.decodeIfPresent(Bool.self, forKey: .tellAuthors)) ?? false
    }

    /// The row's tooltip: how it's connected, or what connecting takes.
    var how: String {
        if connected {
            return "Connected to \(team ?? "your workspace") with your Slack app's tokens. Oby reads messages for the watcher and writes to you"
                + (tellAuthors ? ", and, as you, to the author of a pull request once your review of it is posted." : ".")
                + (socket ? " The channel listener's app-level token is set." : " No app-level token: the channel listener is off.")
        }
        return error ?? "You paste your Slack app's two tokens once (OAuth & Permissions › OAuth Tokens). obid keeps them in its vault."
    }

    /// Whether `text` looks like a token of this kind (`xoxp-` or `xoxb-`), as obid takes it.
    static func isToken(_ text: String, _ prefix: String) -> Bool {
        let token = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return token.hasPrefix(prefix) && (20...512).contains(token.count)
            && token.unicodeScalars.allSatisfy { (0x21...0x7E).contains($0.value) }
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

/// A `watch`, `listen` or `pluginEvent` inbox item (obid only: the watcher, the channel listener, a
/// plug-in's or Sentry's offer), as the Mac's inbox card and notification show it, and a `github`
/// offer, which only notifies (its card is the GitHub item's in Review PR or Issues). Engine's inbox
/// doesn't know these kinds. Only obid's own words are shown (`title`, `text`), and the link when it's
/// https on slack.com or github.com (sentry.io for Sentry's): never what was written (`watch.quoted`,
/// `plugin.quoted`, `github.quoted`).
nonisolated struct WatchNotice: Decodable, Equatable, Identifiable, Sendable {
    static let kinds: Set<String> = ["watch", "listen", "pluginEvent", "github"]
    /// Whether it has a card of its own in the conversation: a `github` offer's is its GitHub item's.
    var carded: Bool { kind != "github" }

    var kind: String
    var id: String
    /// A review ready to approve: its job's id; empty otherwise.
    var job: String
    var title: String
    var text: String
    var options: [String]
    var created: Date
    var done: Date?
    var later: Date?
    /// The message's or the pull request's page: https on slack.com or github.com only.
    var url: URL?
    /// Where it came from, as obid says: `watch.source` (`slack` or `github`), or a `pluginEvent`'s
    /// `plugin.id` (`sentry`, or a plug-in's id).
    var source: String
    /// On a listener's finished review (`watch.review`): exactly what Approve posts on GitHub, the
    /// review an agent wrote, after obid's secret scan. Shown as plain text, never as Markdown.
    var review: String?
    /// How obid sorted it (#1123): `needs_you`, `fyi`, `ignore`, or `pending` while its model sorts it;
    /// nil from a runner that doesn't sort. Only what needs the owner alerts.
    var triage: String?

    private enum Keys: String, CodingKey { case kind, id, job, title, text, options, created, done, later, watch, plugin, triage }
    private struct Place: Decodable { var source: String?; var url: String?; var pr: PR?; var review: String? }
    private struct PR: Decodable { var url: String? }
    private struct Plugin: Decodable { var id: String?; var quoted: Quoted? }
    private struct Quoted: Decodable { var url: String? }

    init(kind: String = "watch", id: String, job: String = "", title: String, text: String, options: [String] = ["Dismiss"], created: Date,
         done: Date? = nil, later: Date? = nil, url: URL? = nil, source: String = "slack", review: String? = nil, triage: String? = nil) {
        (self.kind, self.id, self.job, self.title, self.text, self.options) = (kind, id, job, title, text, options)
        (self.created, self.done, self.later, self.url, self.source, self.review, self.triage) = (created, done, later, url, source, review, triage)
    }

    init(from decoder: any Decoder) throws {
        let keys = try decoder.container(keyedBy: Keys.self)
        kind = try keys.decode(String.self, forKey: .kind)
        id = try keys.decode(String.self, forKey: .id)
        job = (try? keys.decodeIfPresent(String.self, forKey: .job)) ?? ""
        title = try keys.decode(String.self, forKey: .title)
        text = try keys.decode(String.self, forKey: .text)
        options = (try? keys.decodeIfPresent([String].self, forKey: .options)) ?? []
        created = try keys.decode(Date.self, forKey: .created)
        done = try? keys.decodeIfPresent(Date.self, forKey: .done)
        later = try? keys.decodeIfPresent(Date.self, forKey: .later)
        let place = try? keys.decodeIfPresent(Place.self, forKey: .watch)
        let plugin = try? keys.decodeIfPresent(Plugin.self, forKey: .plugin)
        source = place?.source ?? plugin?.id ?? "slack"
        let sentry = source == "sentry"
        // What a plug-in wrote never opens; only Sentry's own offer links to its issue, on sentry.io.
        let issue = sentry ? plugin?.quoted?.url.flatMap { Self.link($0, on: ["sentry.io"]) } : nil
        url = (place?.pr?.url ?? place?.url).flatMap { Self.link($0) } ?? issue
        review = place?.review
        triage = try? keys.decodeIfPresent(String.self, forKey: .triage)
    }

    /// `text` as a link the card may open: https, no login, on one of `hosts` (slack.com or github.com)
    /// or a subdomain, with nothing that could end it early.
    static func link(_ text: String, on hosts: [String] = ["slack.com", "github.com"]) -> URL? {
        guard !text.contains(where: { $0.isWhitespace || $0.isNewline || "<>|\"".contains($0) }),
              let url = URL(string: text), url.scheme == "https", url.user() == nil, url.password() == nil,
              let host = url.host()?.lowercased() else { return nil }
        let allowed = hosts.contains { host == $0 || host.hasSuffix("." + $0) }
        return allowed ? url : nil
    }

    /// Open, and not put off until later.
    func waiting(at now: Date = .now) -> Bool { done == nil && (later.map { $0 <= now } ?? true) }

    /// The ones of these kinds in a `GET /v1/inbox` answer.
    static func list(_ data: Data) -> [WatchNotice] {
        guard let items = (try? JSONSerialization.jsonObject(with: data)) as? [Any] else { return [] }
        return items.compactMap { item in
            (try? JSONSerialization.data(withJSONObject: item))
                .flatMap { try? Runner.decoder.decode(WatchNotice.self, from: $0) }
                .flatMap { kinds.contains($0.kind) ? $0 : nil }
        }
    }

    /// Whether a notification shows for it: open, not put off, from the last hour (an older one is a
    /// replay after a reconnect), not shown already, and needing the owner (or not sorted yet).
    static func shows(_ notice: WatchNotice, told: Set<String>, now: Date = .now) -> Bool {
        notice.waiting(at: now) && notice.created > now.addingTimeInterval(-3600) && !told.contains(notice.id) && notice.needsYou
    }

    /// It needs the owner: obid sorted it so, or doesn't sort (nil). Not while it's `pending` (it alerts
    /// once sorted `needs_you`), and not for a sort this app doesn't know.
    var needsYou: Bool { triage == nil || triage == "needs_you" }
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

    /// Whether a posted review's author is told on Slack, as the owner.
    func setSlackTellAuthors(_ on: Bool) async throws -> SlackStatus {
        struct Body: Encodable { var tellAuthors: Bool }
        return try await call("PATCH", "v1/slack", body: Body(tellAuthors: on))
    }

    /// obid forgets the Slack tokens: the watcher reads only GitHub until they're pasted again.
    func disconnectSlack() async throws {
        try await send("DELETE", "v1/slack")
    }

    /// Settles a `watch` or `listen` item: Dismiss, Approve (a review's: obid posts it on GitHub),
    /// done or later. Engine's inbox doesn't read these kinds, so the answer is read as one.
    func settle(notice id: String, answer: String? = nil, later: Date? = nil) async throws -> WatchNotice {
        struct Body: Encodable { var answer: String?; var later: Date? }
        let data = try await send("POST", "v1/inbox/\(id)/answer", body: Body(answer: answer, later: later))
        return try Runner.decoder.decode(WatchNotice.self, from: data)
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
