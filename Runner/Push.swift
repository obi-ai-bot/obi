import Crypto
import Foundation
import HTTPTypes
@testable import ObyEngine

/// Push to the iPhone and the Apple Watch, through Apple's push service: the Live Activity keeps the
/// Lock Screen and Dynamic Island in step with the jobs while Oby is suspended, an alert says when
/// a job needs the user (its own publish failed, it failed, or it was interrupted), and nothing
/// else, to the phone and the Watch alike, and a WidgetKit push refreshes the Watch's complications
/// when what they count changes. On only when `folder`
/// holds `apns.json` (`{"team": …, "key": …}`) and that key's `AuthKey_<key>.p8`, which never
/// leaves the folder.
@MainActor
final class Push {
    /// A push token from a phone, as `POST /v1/activities` and `POST /v1/notifications` take it,
    /// or from a Watch, through the Watch API's `POST /v1/notifications`.
    struct Token: Codable, Equatable {
        /// Hex.
        var token: String
        /// "update" (one activity), "start" (push-to-start), "alert" (the app's device token) or
        /// "widget" (the Watch's complications).
        var kind: String
        /// The app's bundle ID.
        var topic: String
        /// "development" or "production".
        var environment: String
        /// The paired Watch it came from, or nil for the phone's.
        var watch: String? = nil
    }

    /// One push to send.
    struct Delivery: Equatable {
        var token: Token
        var body: Data
        /// `apns-push-type`.
        var type: String
        var priority: Int
        var collapse: String?
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
            if let title = job.brainTitle {
                self.title = title
            } else if let number = job.pr ?? job.issue {
                title = "\(job.kind.rawValue.capitalized) \(job.repoName) #\(number)"
            } else {
                title = job.request.split(separator: "\n").first.map(String.init) ?? job.request
            }
            switch job.status {
            // What it waits for, as the apps' rows say it: "After #223 merges" (#238).
            case .queued where job.waiting != nil: line = job.waiting.map { $0.text.prefix(1).uppercased() + $0.text.dropFirst() } ?? ""
            case .queued, .running: line = job.step.isEmpty ? "Starting…" : job.step
            case .done: line = job.summary.split(separator: "\n").first.map(String.init) ?? "Done"
            case .failed, .stopped, .interrupted:
                line = job.summary.split(separator: "\n").first.map(String.init) ?? job.status.rawValue.capitalized
            }
            started = (job.started ?? job.created).timeIntervalSinceReferenceDate
            // "waiting" for a job queued behind something: the Live Activity says Waiting, in gray.
            status = job.isWaiting ? "waiting" : job.status.rawValue
            agent = job.agent
        }
    }

    /// What a job needs from the user, the only thing an alert is for.
    enum Notice: String, Codable {
        /// Done with commits Oby couldn't publish by itself: it waits for Publish.
        case ready
        case failed
        case interrupted
        /// Oby's review requested changes for the last time it may: a person takes it from here.
        case review
        /// Its agent asked the user something and waits for the answer (the inbox has it).
        case question
        /// Oby's merge stopped: it couldn't merge, or the Mac check failed with no round left.
        case merge
        /// Its agent waits for the user's OK on a command or an edit (the inbox has it).
        case permission
    }

    private struct Signer {
        var team: String
        var keyID: String
        var key: P256.Signing.PrivateKey
    }

    private let desk: Desk
    private let signer: Signer?
    private let file: URL
    private(set) var tokens: [Token] = []
    /// What each job's alert last said, kept in `notices.json` so a restart doesn't say it again.
    private let noticesFile: URL
    private var notified: [String: Notice] = [:]
    /// Push-to-start went out for the jobs running now.
    private var started = false
    private var lastSent: State?
    /// What the Watch's complications counted when they were last pushed.
    private var lastGlance: Glance?
    private var jwt: (token: String, made: Date)?
    private var sending: Task<Void, Never>?
    private var waiting = false

    var isOn: Bool { signer != nil }

    init(desk: Desk, folder: URL) {
        self.desk = desk
        file = folder.appending(path: "tokens.json")
        noticesFile = folder.appending(path: "notices.json")
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
        if let saved = try? JSONDecoder().decode([String: Notice].self, from: Data(contentsOf: noticesFile)) {
            notified = saved
            // Jobs a restart interrupted say so now.
            sending = Task { await notify(now: .now) }
        } else {
            // The first time, what the jobs already need isn't news.
            notified = Self.notices(desk.jobs, after: [:]).notified
            saveNotices()
        }
    }

    /// Keeps a phone's token and says whether the runner pushes. A newer push-to-start token
    /// replaces the older one for the same app.
    func register(_ token: Token) throws -> Bool {
        guard token.token.count.isMultiple(of: 2), (16...400).contains(token.token.count),
              token.token.allSatisfy(\.isHexDigit) else {
            throw APIError(.unprocessableContent, "token isn't a push token in hex.")
        }
        guard ["update", "start", "alert", "widget"].contains(token.kind) else { throw APIError(.unprocessableContent, "kind is update or start.") }
        guard ["development", "production"].contains(token.environment) else {
            throw APIError(.unprocessableContent, "environment is development or production.")
        }
        guard token.topic.wholeMatch(of: /[A-Za-z0-9.\-]{1,155}/) != nil else {
            throw APIError(.unprocessableContent, "topic is the app's bundle ID.")
        }
        guard isOn else { return false }
        var token = token
        token.token = token.token.lowercased()
        tokens.removeAll { $0.token == token.token || (token.kind == "start" && $0.kind == "start" && $0.topic == token.topic && $0.environment == token.environment)
            || (token.kind == "widget" && $0.kind == "widget" && $0.watch == token.watch) }
        tokens.append(token)
        save()
        return true
    }

    /// A Watch was unpaired: nothing goes to it any more.
    func forget(watch: String) {
        guard tokens.contains(where: { $0.watch == watch }) else { return }
        tokens.removeAll { $0.watch == watch }
        save()
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
            await notify(now: .now)
            await refreshComplications(now: .now)
        }
    }

    /// The Live Activity.
    private func send() async {
        let active = desk.jobs.filter(\.isActive)
        let updates = tokens.filter { $0.kind == "update" }
        let now = Date.now
        // A job working first, and only those count as working: not the ones waiting their turn (#238).
        if let job = active.first(where: \.isWorking) ?? active.first {
            let state = State(job, working: active.count(where: \.isWorking))
            if !updates.isEmpty {
                guard state != lastSent else { return }
                lastSent = state
                for token in updates { await activity(["event": "update", "content-state": state], to: token, priority: 5, now: now) }
            } else if !started {
                started = true
                lastSent = state
                let alert = ["title": state.title, "body": state.line]
                for token in tokens where token.kind == "start" {
                    await activity(["event": "start", "content-state": state, "attributes-type": "ObyActivity",
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
            // No alert: a job that needs the user says so with its own (`notify`).
            for token in updates {
                await activity(["event": "end", "content-state": state, "dismissal-date": dismissal], to: token, priority: 10, now: now)
            }
            tokens.removeAll { updates.contains($0) }
            save()
        }
    }

    /// Alerts for what changed in what the jobs need: one per job, with the job's id as its collapse
    /// ID so a newer state replaces the older one, and a clearing push once a job needs nothing any
    /// more (published, from the iPhone or the Mac, dismissed, or running again).
    private func notify(now: Date) async {
        let (changes, notified) = Self.notices(desk.jobs, after: self.notified)
        guard notified != self.notified else { return }
        self.notified = notified
        saveNotices()
        for delivery in Self.alerts(changes, to: tokens) {
            await deliver(delivery.body, to: delivery.token, type: delivery.type, priority: delivery.priority, collapse: delivery.collapse, now: now)
        }
    }

    /// The alerts for `changes`, to every alert token, the phone's and the Watches' alike: the same
    /// payload with the same collapse ID, so a Watch that gets its own and the phone's shows one.
    static func alerts(_ changes: [(Job, Notice?)], to tokens: [Token]) -> [Delivery] {
        let alerts = tokens.filter { $0.kind == "alert" }
        return changes.flatMap { job, notice -> [Delivery] in
            guard let body = try? notification(notice, for: job) else { return [] }
            return alerts.map { token in
                notice == nil ? Delivery(token: token, body: body, type: "background", priority: 5)
                    : Delivery(token: token, body: body, type: "alert", priority: 10, collapse: job.id)
            }
        }
    }

    /// The Watch's complications count what needs the user, what's working and what waits: when
    /// any changes, a WidgetKit push has them reload (they fetch the jobs themselves).
    private func refreshComplications(now: Date) async {
        let glance = Self.glance(desk.jobs)
        guard glance != lastGlance else { return }
        lastGlance = glance
        for delivery in Self.complications(to: tokens) {
            await deliver(delivery.body, to: delivery.token, type: delivery.type, priority: delivery.priority, now: now)
        }
    }

    /// What the complications count.
    struct Glance: Equatable {
        var needs: Int
        var working: Int
        var waiting = 0
    }

    static func glance(_ jobs: [Job]) -> Glance {
        Glance(needs: jobs.count(where: \.needsYou), working: jobs.count(where: \.isWorking), waiting: jobs.count(where: \.isWaiting))
    }

    /// A WidgetKit push to every Watch's widget token: `{"aps": {"content-changed": true}}`.
    static func complications(to tokens: [Token]) -> [Delivery] {
        let body = Data(#"{"aps":{"content-changed":true}}"#.utf8)
        return tokens.filter { $0.kind == "widget" }.map { Delivery(token: $0, body: body, type: "widgets", priority: 10) }
    }

    private func activity(_ aps: [String: any Encodable], to token: Token, priority: Int, now: Date) async {
        guard let body = try? Self.payload(aps, now: now) else { return }
        await deliver(body, to: token, type: "liveactivity", priority: priority, now: now)
    }

    /// Sends one push, the vault's secrets taken out first (none goes when the vault can't be read);
    /// a token Apple no longer takes is dropped.
    private func deliver(_ raw: Data, to token: Token, type: String, priority: Int, collapse: String? = nil, now: Date) async {
        guard let signer else { return }
        let body: Data
        do {
            body = try Vault.shared.scrubbed(raw)
        } catch {
            Logger.runner.error("push held: the secret scan can't read the vault (\(error.localizedDescription, privacy: .public))")
            return
        }
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
        let topic = switch type {
        case "liveactivity": "\(token.topic).push-type.liveactivity"
        case "widgets": "\(token.topic).push-type.widgets"
        default: token.topic
        }
        let config = [
            "url = \(Self.quoted("https://\(host)/3/device/\(token.token)"))",
            "request = \"POST\"",
            "header = \(Self.quoted("authorization: bearer \(bearer)"))",
            "header = \(Self.quoted("apns-push-type: \(type)"))",
            "header = \(Self.quoted("apns-topic: \(topic)"))",
            "header = \"apns-priority: \(priority)\"",
            "header = \"content-type: application/json\"",
        ] + (collapse.map { ["header = \(Self.quoted("apns-collapse-id: \($0)"))"] } ?? []) + [
            "data-binary = \(Self.quoted(String(decoding: body, as: UTF8.self)))",
            "silent", "max-time = 20", "write-out = \"\\n%{http_code}\"",
        ]
        let lines = config.joined(separator: "\n") + "\n"
        let name = String(token.token.prefix(8))
        guard let result = try? await Shell.run(["curl", "--http2", "-K", "-"], input: Data(lines.utf8), timeout: 30) else {
            Logger.runner.error("push to \(name, privacy: .public)…: curl didn't run")
            return
        }
        let answered = String(decoding: result.out, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false)
        let code = answered.last.flatMap { Int($0) } ?? 0
        guard code != 200 else { return }
        let answer = answered.dropLast().joined(separator: "\n")
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

    private func saveNotices() {
        guard let data = try? JSONEncoder().encode(notified) else { return }
        try? data.write(to: noticesFile, options: .atomic)
    }

    // MARK: Notices

    /// Nothing for a job the user dismissed: its alert clears.
    static func notice(for job: Job) -> Notice? {
        if job.waitsForPermission { return .permission }
        if job.waitsForAnswer { return .question }
        guard job.needsYou else { return nil }
        if job.canPublish { return .ready }
        if job.reviewNeedsYou { return .review }
        if job.mergeNeedsYou { return .merge }
        // Xcode Cloud still fails after Oby handed it back (#122): its inbox item is a failure's.
        if job.cloudNeedsYou { return .failed }
        switch job.status {
        case .failed: return .failed
        case .interrupted: return .interrupted
        default: return nil
        }
    }

    /// What each job needs now, against what its alert last said: the jobs whose alert changes
    /// (nil: clear it), and what to remember. Jobs the desk no longer lists are forgotten.
    static func notices(_ jobs: [Job], after notified: [String: Notice]) -> (changes: [(Job, Notice?)], notified: [String: Notice]) {
        var changes: [(Job, Notice?)] = []
        var now: [String: Notice] = [:]
        for job in jobs {
            let notice = notice(for: job)
            now[job.id] = notice
            if notice != notified[job.id] { changes.append((job, notice)) }
        }
        return (changes, now)
    }

    /// The alert for `notice`, with the job's id for the app to open (`category` "ready" offers
    /// Publish), or for nil the background push that clears it.
    static func notification(_ notice: Notice?, for job: Job) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let notice else {
            return try encoder.encode(Fields(["aps": Fields(["content-available": 1]), "clear": job.id]))
        }
        let state = State(job, working: 0)
        let title = switch notice {
        case .ready: "Couldn't publish: \(state.title)"
        case .failed: "Failed: \(state.title)"
        case .interrupted: "Interrupted: \(state.title)"
        case .review: "Changes requested: \(state.title)"
        case .question: "Question: \(state.title)"
        case .merge: "Not merged: \(state.title)"
        case .permission: "\(job.permission?.title ?? "Allow it")?"
        }
        // Why its own publish failed, when that's what it needs; why Oby's review stopped.
        let body = switch notice {
        case .ready: job.publishError ?? state.line
        case .review: job.review?.stopReason ?? Review.stopLine
        case .question: job.question?.text ?? state.line
        case .merge: job.mergeError ?? job.macCheck.map { $0.problem ?? $0.failureLine + (job.checkStop.map { " " + $0 } ?? "") } ?? state.line
        case .failed, .interrupted: state.line
        case .permission: "\(state.title): \(job.permission.map { String(($0.detail.isEmpty ? $0.title : $0.detail).prefix(200)) } ?? state.line)"
        }
        let aps: [String: any Encodable] = ["alert": ["title": title, "body": body], "sound": "default",
                                            "category": notice == .ready ? "ready" : notice == .permission ? "permission" : "job", "thread-id": "jobs"]
        return try encoder.encode(Fields(["aps": Fields(aps), "job": job.id]))
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
