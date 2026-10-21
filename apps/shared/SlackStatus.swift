import Foundation

/// Slack, connected once on obid (docs/runner-api.md, "obid only: Slack"). obid is the public client
/// of the owner's own Slack app and holds the login: the Mac only learns whether it's connected,
/// opens Slack's own page, and turns the watcher's Slack message on or off. No token reaches it.
nonisolated struct SlackStatus: Decodable, Equatable, Sendable {
    /// The sign-in under way: Slack's page, which hands the login back to obid's own page.
    struct SignIn: Decodable, Equatable, Sendable {
        var url: URL
        var expiresAt: Date?

        /// Only Slack's own page, over https, with no login in it, is ever opened.
        var opens: Bool {
            url.scheme?.lowercased() == "https" && url.host()?.lowercased() == "slack.com" && url.user() == nil && url.password() == nil
        }
    }

    /// What it does, as Sangam's Connectors says it.
    static let about = "Read and send messages"

    var connected = false
    /// The workspace's name.
    var team: String?
    /// The Slack app's Client ID obid kept (not a secret), or nil before the first sign-in.
    var clientId: String?
    /// What the app's Redirect URLs must list.
    var redirect: String?
    var signIn: SignIn?
    /// Why the last sign-in or call failed, in obid's words, or nil.
    var error: String?

    private enum Keys: String, CodingKey { case connected, team, clientId, redirect, signIn, error }

    init(connected: Bool = false, team: String? = nil, clientId: String? = nil, redirect: String? = nil,
         signIn: SignIn? = nil, error: String? = nil) {
        (self.connected, self.team, self.clientId, self.redirect, self.signIn, self.error) = (connected, team, clientId, redirect, signIn, error)
    }

    init(from decoder: any Decoder) throws {
        let keys = try decoder.container(keyedBy: Keys.self)
        connected = (try? keys.decodeIfPresent(Bool.self, forKey: .connected)) ?? false
        team = try? keys.decodeIfPresent(String.self, forKey: .team)
        clientId = try? keys.decodeIfPresent(String.self, forKey: .clientId)
        redirect = try? keys.decodeIfPresent(String.self, forKey: .redirect)
        signIn = try? keys.decodeIfPresent(SignIn.self, forKey: .signIn)
        error = try? keys.decodeIfPresent(String.self, forKey: .error)
    }

    /// The row's tooltip: how it's connected, or what connecting does.
    var how: String {
        if connected { return "Connected to \(team ?? "your workspace") as you, through your workspace's Oby app. Oby reads messages for the watcher and writes only to you." }
        if signIn != nil { return "Connecting in your browser…" }
        return error ?? "You connect once, on Slack's own page, with your workspace's Oby app (its Client ID)."
    }

    /// Whether `text` is a Slack app's Client ID, as obid takes it: digits, a dot, digits.
    static func isClientID(_ text: String) -> Bool {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 2 && parts.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }
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

    /// Starts connecting obid to Slack with the app `clientID` (nil: the one obid kept).
    func startSlackSignIn(clientID: String?) async throws -> SlackStatus.SignIn {
        struct Body: Encodable { var clientId: String? }
        return try await call("POST", "v1/slack/sign-in", body: Body(clientId: clientID))
    }

    func cancelSlackSignIn() async throws {
        try await send("DELETE", "v1/slack/sign-in")
    }

    /// obid forgets its Slack login: the watcher reads only GitHub until it's connected again.
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
