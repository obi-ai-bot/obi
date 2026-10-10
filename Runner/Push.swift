import Crypto
import Foundation
import HTTPTypes
@testable import ObyEngine
#if canImport(OSLog)
import OSLog
#endif

/// Live Activity push: keeps the iPhone's Lock Screen and Dynamic Island in step with the jobs
/// while Oby is suspended, through Apple's push service. On only when `folder` holds `apns.json`
/// (`{"team": …, "key": …}`) and that key's `AuthKey_<key>.p8`, which never leaves the folder.
@MainActor
final class Push {
    /// A Live Activity push token from a phone, as `POST /v1/activities` takes it.
    struct Token: Codable, Equatable {
        /// Hex.
        var token: String
        /// "update" (one activity) or "start" (push-to-start).
        var kind: String
        /// The app's bundle ID.
        var topic: String
        /// "development" or "production".
        var environment: String
    }

    /// The Live Activity's `ContentState` (LiveActivity/ObyActivity.swift), as ActivityKit decodes
    /// it: `started` is a Date's default Codable, seconds since 2001.
    struct State: Encodable, Equatable {
        var working: Int
        var title: String
        var line: String
        var started: Double
        var status: String
        var agent: String

        /// What iOS/JobsActivity.swift shows for `job`.
        init(_ job: Job, working: Int) {
            self.working = working
            if let number = job.pr ?? job.issue {
                title = "\(job.kind.rawValue.capitalized) \(job.repoName) #\(number)"
            } else {
                title = job.request.split(separator: "\n").first.map(String.init) ?? job.request
            }
            switch job.status {
            case .queued, .running: line = job.step.isEmpty ? "Starting…" : job.step
            case .done: line = job.summary.split(separator: "\n").first.map(String.init) ?? "Done"
            case .failed, .stopped, .interrupted:
                line = job.summary.split(separator: "\n").first.map(String.init) ?? job.status.rawValue.capitalized
            }
            started = (job.started ?? job.created).timeIntervalSinceReferenceDate
            status = job.status.rawValue
            agent = job.agent
        }
    }

    private struct Signer {
        var team: String
        var keyID: String
        var key: P256.Signing.PrivateKey
    }

    private let desk: Desk
    private let signer: Signer?
    private let file: URL
    private var tokens: [Token] = []
    /// Push-to-start went out for the jobs running now.
    private var started = false
    private var lastSent: State?
    private var jwt: (token: String, made: Date)?
    private var sending: Task<Void, Never>?
    private var waiting = false

    var isOn: Bool { signer != nil }

    init(desk: Desk, folder: URL) {
        self.desk = desk
        file = folder.appending(path: "tokens.json")
        struct Config: Decodable { var team: String; var key: String }
        guard let data = try? Data(contentsOf: folder.appending(path: "apns.json")) else {
            signer = nil
            Logger.runner.notice("Live Activity push is off: no apns.json in \(folder.path, privacy: .public)")
            return
        }
        guard let config = try? JSONDecoder().decode(Config.self, from: data),
              let pem = try? String(contentsOf: folder.appending(path: "AuthKey_\(config.key).p8"), encoding: .utf8),
              let key = try? P256.Signing.PrivateKey(pemRepresentation: pem) else {
            signer = nil
            Logger.runner.error("Live Activity push is off: apns.json or its AuthKey .p8 in \(folder.path, privacy: .public) can't be read")
            return
        }
        signer = Signer(team: config.team, keyID: config.key, key: key)
        tokens = (try? JSONDecoder().decode([Token].self, from: Data(contentsOf: file))) ?? []
        Logger.runner.notice("Live Activity push is on (key \(config.key, privacy: .public), \(self.tokens.count, privacy: .public) tokens)")
    }

    /// Keeps a phone's token and says whether the runner pushes. A newer push-to-start token
    /// replaces the older one for the same app.
    func register(_ token: Token) throws -> Bool {
        guard token.token.count.isMultiple(of: 2), (16...400).contains(token.token.count),
              token.token.allSatisfy(\.isHexDigit) else {
            throw APIError(.unprocessableContent, "token isn't a push token in hex.")
        }
        guard ["update", "start"].contains(token.kind) else { throw APIError(.unprocessableContent, "kind is update or start.") }
        guard ["development", "production"].contains(token.environment) else {
            throw APIError(.unprocessableContent, "environment is development or production.")
        }
        guard token.topic.wholeMatch(of: /[A-Za-z0-9.\-]{1,155}/) != nil else {
            throw APIError(.unprocessableContent, "topic is the app's bundle ID.")
        }
        guard isOn else { return false }
        var token = token
        token.token = token.token.lowercased()
        tokens.removeAll { $0.token == token.token || (token.kind == "start" && $0.kind == "start" && $0.topic == token.topic && $0.environment == token.environment) }
        tokens.append(token)
        save()
        return true
    }

    /// A job changed: two seconds later (time for an open app to hand over its own activity's
    /// token, and for a burst of steps to settle), push what the jobs look like then.
    func changed() {
        guard isOn, !waiting else { return }
        waiting = true
        let previous = sending
        sending = Task {
            try? await Task.sleep(for: .seconds(2))
            await previous?.value
            waiting = false
            await send()
        }
    }

    private func send() async {
        let active = desk.jobs.filter(\.isActive)
        let updates = tokens.filter { $0.kind == "update" }
        let now = Date.now
        if let job = active.first {
            let state = State(job, working: active.count)
            if !updates.isEmpty {
                guard state != lastSent else { return }
                lastSent = state
                for token in updates { await deliver(["event": "update", "content-state": state], to: token, priority: 5, now: now) }
            } else if !started {
                started = true
                lastSent = state
                let alert = ["title": state.title, "body": state.line]
                for token in tokens where token.kind == "start" {
                    await deliver(["event": "start", "content-state": state, "attributes-type": "ObyActivity",
                                   "attributes": [String: String](), "alert": alert], to: token, priority: 10, now: now)
                }
            }
        } else {
            started = false
            lastSent = nil
            guard !updates.isEmpty,
                  let last = desk.jobs.max(by: { ($0.finished ?? .distantPast) < ($1.finished ?? .distantPast) }) else { return }
            let state = State(last, working: 0)
            let dismissal = Int((last.finished ?? now).addingTimeInterval(15 * 60).timeIntervalSince1970)
            let alert = ["title": last.status == .done ? "Done" : "Failed", "body": state.title]
            for token in updates {
                await deliver(["event": "end", "content-state": state, "dismissal-date": dismissal, "alert": alert], to: token, priority: 10, now: now)
            }
            tokens.removeAll { updates.contains($0) }
            save()
        }
    }

    /// Sends one push; a token Apple no longer takes is dropped.
    private func deliver(_ aps: [String: any Encodable], to token: Token, priority: Int, now: Date) async {
        guard let signer, let body = try? Self.payload(aps, now: now) else { return }
        // Apple takes a provider token for an hour, and refuses new ones more often than every 20 minutes.
        let bearer: String
        if let jwt, now.timeIntervalSince(jwt.made) < 50 * 60 {
            bearer = jwt.token
        } else {
            guard let made = try? Self.jwt(team: signer.team, keyID: signer.keyID, key: signer.key, now: now) else { return }
            jwt = (made, now)
            bearer = made
        }
        let host = token.environment == "production" ? "api.push.apple.com" : "api.sandbox.push.apple.com"
        let config = [
            "url = \(Self.quoted("https://\(host)/3/device/\(token.token)"))",
            "request = \"POST\"",
            "header = \(Self.quoted("authorization: bearer \(bearer)"))",
            "header = \"apns-push-type: liveactivity\"",
            "header = \(Self.quoted("apns-topic: \(token.topic).push-type.liveactivity"))",
            "header = \"apns-priority: \(priority)\"",
            "header = \"content-type: application/json\"",
            "data-binary = \(Self.quoted(String(decoding: body, as: UTF8.self)))",
            "silent", "max-time = 20", "write-out = \"\\n%{http_code}\"",
        ].joined(separator: "\n") + "\n"
        let name = String(token.token.prefix(8))
        guard let result = try? await Shell.run(["curl", "--http2", "-K", "-"], input: Data(config.utf8), timeout: 30) else {
            Logger.runner.error("push to \(name, privacy: .public)…: curl didn't run")
            return
        }
        let lines = String(decoding: result.out, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false)
        let code = lines.last.flatMap { Int($0) } ?? 0
        guard code != 200 else { return }
        let answer = lines.dropLast().joined(separator: "\n")
        Logger.runner.error("push to \(name, privacy: .public)… answered \(code, privacy: .public): \(answer, privacy: .public)")
        if code == 410 || answer.contains("BadDeviceToken") {
            tokens.removeAll { $0.token == token.token }
            save()
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(tokens) else { return }
        try? data.write(to: file, options: .atomic)
    }

    // MARK: Payloads

    /// `{"aps": {…, "timestamp": now}}`, with `content-state` as the app's ContentState.
    nonisolated static func payload(_ aps: [String: any Encodable], now: Date) throws -> Data {
        var aps = aps
        aps["timestamp"] = Int(now.timeIntervalSince1970)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(["aps": Fields(aps)])
    }

    /// The provider token: ES256 over `{"alg", "kid"}.{"iss", "iat"}`, base64url, no padding.
    nonisolated static func jwt(team: String, keyID: String, key: P256.Signing.PrivateKey, now: Date) throws -> String {
        let header = try JSONSerialization.data(withJSONObject: ["alg": "ES256", "kid": keyID], options: .sortedKeys)
        let claims = try JSONSerialization.data(withJSONObject: ["iss": team, "iat": Int(now.timeIntervalSince1970)] as [String: Any], options: .sortedKeys)
        let input = base64URL(header) + "." + base64URL(claims)
        let signature = try key.signature(for: Data(input.utf8))
        return input + "." + base64URL(signature.rawRepresentation)
    }

    nonisolated static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacing("+", with: "-").replacing("/", with: "_").replacing("=", with: "")
    }

    /// A curl config value: quoted, with `\` and `"` escaped.
    nonisolated static func quoted(_ value: String) -> String {
        "\"" + value.replacing("\\", with: "\\\\").replacing("\"", with: "\\\"") + "\""
    }
}

/// Encodes a dictionary of mixed values, as APNs payloads are.
private struct Fields: Encodable {
    struct Key: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    let fields: [String: any Encodable]
    init(_ fields: [String: any Encodable]) { self.fields = fields }

    func encode(to encoder: any Encoder) throws {
        var keys = encoder.container(keyedBy: Key.self)
        for (name, value) in fields { try keys.encode(value, forKey: Key(stringValue: name)) }
    }
}
