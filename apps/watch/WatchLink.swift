import CryptoKit
import Foundation
import Security

/// The watch's own line to the runner, for when its iPhone is out of reach: the Watch API
/// (docs/runner-api.md, "The Watch API") through a Cloudflare Tunnel, with plain HTTPS from
/// URLSession. Cloudflare Access lets a request through with the service token the iPhone handed
/// over at pairing; the runner then checks the request's signature, made with this watch's
/// Secure Enclave key, with a time and a fresh nonce. Compiled into the app and the widget
/// extension, which fetches the jobs itself when a WidgetKit push asks it to reload.
nonisolated struct WatchLink: Sendable {
    /// What pairing left here, from the iPhone (apps/ios/app/WatchPairing.swift).
    struct Pairing: Codable, Equatable, Sendable {
        /// This watch's id on the runner.
        var watch: String
        /// The Watch API's address, through the tunnel.
        var url: URL
        /// The Access service token.
        var clientID: String
        var clientSecret: String
    }

    /// The runner can't write speech down: dictate instead.
    struct SpeechUnavailable: LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    let pairing: Pairing

    // MARK: Keeping it

    /// The pairing, or nil when this watch isn't paired.
    static var saved: WatchLink? {
        guard let data = Keychain.read("pairing"), let pairing = try? JSONDecoder().decode(Pairing.self, from: data) else { return nil }
        return WatchLink(pairing: pairing)
    }

    static func save(_ pairing: Pairing) throws {
        try Keychain.write(try JSONEncoder().encode(pairing), as: "pairing")
    }

    /// Unpaired on the iPhone: the token and the address go. The key stays, so pairing again
    /// gets the same id.
    static func forget() {
        Keychain.delete("pairing")
    }

    /// The public half of this watch's key, X9.63, for the iPhone to pair. Made the first time.
    static func publicKey() throws -> Data {
        try key().publicKey.x963Representation
    }

    /// The key lives in the Secure Enclave; the keychain keeps the wrapped blob only this
    /// watch's enclave can use. Usable after the first unlock, so the complications can fetch
    /// in the background; the watch locks itself when it's off the wrist.
    private static func key() throws -> SecureEnclave.P256.Signing.PrivateKey {
        if let blob = Keychain.read("key") {
            return try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: blob)
        }
        guard SecureEnclave.isAvailable else { throw RunnerError(message: "This watch has no Secure Enclave.") }
        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly, [.privateKeyUsage], &error) else {
            throw error?.takeRetainedValue() ?? RunnerError(message: "This watch can't make a key.")
        }
        let key = try SecureEnclave.P256.Signing.PrivateKey(accessControl: access)
        try Keychain.write(key.dataRepresentation, as: "key")
        return key
    }

    // MARK: The Watch API

    func jobs() async throws -> [Job] { try await call("GET", "v1/jobs?limit=50") }
    func job(_ id: String) async throws -> Job { try await call("GET", "v1/jobs/\(id)") }

    func plan(_ said: String, answer: (question: String, option: String)? = nil) async throws -> PlanResult {
        struct Answer: Encodable { var question: String; var option: String }
        struct Body: Encodable { var said: String; var answer: Answer? }
        return try await call("POST", "v1/plans", body: Body(said: said, answer: answer.map { Answer(question: $0.question, option: $0.option) }), timeout: Runner.planTimeout)
    }

    /// Stop: the turn Oby is working on ends (#304). A Watch API without it answers 404: that
    /// waits for the iPhone.
    func stopConversation() async throws {
        let (data, response) = try await URLSession.shared.data(for: try signed("POST", "v1/conversation/stop", body: Data()))
        do {
            try Runner.check(response, data)
        } catch let error as RunnerError where error.status == 404 {
            throw RunnerError(message: "Stopping needs your iPhone in reach.", status: 404)
        }
    }

    func tell(_ id: String, _ text: String) async throws -> Job {
        struct Body: Encodable { var text: String }
        return try await call("POST", "v1/jobs/\(id)/messages", body: Body(text: text))
    }

    func dismiss(_ id: String) async throws -> Job { try await call("POST", "v1/jobs/\(id)/dismiss") }

    /// Starts a job waiting for its `startWhen` now (#216).
    func startNow(_ id: String) async throws -> Job { try await call("POST", "v1/jobs/\(id)/start") }

    /// Allow, Always allow or Deny (with words for the agent). A Watch API without it answers 404:
    /// that waits for the iPhone.
    func answer(_ id: String, permission: String, _ decision: RunnerPermission.Decision, message: String?) async throws -> Job {
        struct Body: Encodable { var id: String; var decision: RunnerPermission.Decision; var message: String? }
        do {
            return try await call("POST", "v1/jobs/\(id)/permission", body: Body(id: permission, decision: decision, message: message))
        } catch let error as RunnerError where error.status == 404 {
            throw RunnerError(message: "Answering this needs your iPhone in reach.", status: 404)
        }
    }

    func move(_ id: String, agent: String?, account: String?, model: String?) async throws -> Job {
        try await call("POST", "v1/jobs/\(id)/move", body: MoveBody(agent: agent, account: account, model: model))
    }

    func publishAction(_ id: String) async throws -> String {
        struct Answer: Decodable { var action: String }
        let answer: Answer = try await call("GET", "v1/jobs/\(id)/publish")
        return answer.action
    }

    /// The crown's approval: the signed request is it.
    func publish(_ id: String, action: String) async throws -> URL {
        struct Body: Encodable { var action: String }
        struct Answer: Decodable { var url: URL }
        let answer: Answer = try await call("POST", "v1/jobs/\(id)/publish", body: Body(action: action))
        return answer.url
    }

    /// This watch's device token ("alert") or its complications' ("widget").
    func registerPush(_ token: Data, kind: String, topic: String) async throws -> Bool {
        struct Body: Encodable { var token: String; var topic: String; var environment: String; var kind: String }
        struct Answer: Decodable { var push: Bool }
        #if DEBUG
        let environment = "development"
        #else
        let environment = "production"
        #endif
        let hex = token.map { String(format: "%02x", $0) }.joined()
        let answer: Answer = try await call("POST", "v1/notifications", body: Body(token: hex, topic: topic, environment: environment, kind: kind))
        return answer.push
    }

    /// One piece of what the mic hears, answered with the whole transcript so far (it can change),
    /// or nil when the runner sent none. `final` (its body may be empty) ends it with the final
    /// words. The runner answers `501` while it can't write speech down: that's SpeechUnavailable.
    func speech(request: String, sequence: Int, audio: Data, final: Bool = false) async throws -> String? {
        let target = "v1/speech?request=\(request)&sequence=\(sequence)" + (final ? "&final=true" : "")
        var urlRequest = try signed("POST", target, body: audio)
        urlRequest.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        // Whisper writes all of it down again for the final words.
        if final { urlRequest.timeoutInterval = 60 }
        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        if (response as? HTTPURLResponse)?.statusCode == 501 {
            struct Problem: Decodable { var error: String }
            throw SpeechUnavailable(message: (try? JSONDecoder().decode(Problem.self, from: data))?.error ?? "Speech-to-text isn't set up on the runner yet.")
        }
        try Runner.check(response, data)
        struct Answer: Decodable { var text: String? }
        return (try? JSONDecoder().decode(Answer.self, from: data))?.text
    }

    /// The runner's events while Oby is on screen; the caller ends it when Oby leaves the screen.
    func events() -> AsyncThrowingStream<RunnerEvent, Error> {
        AsyncThrowingStream { stream in
            let task = Task {
                do {
                    var request = try signed("GET", "v1/events", body: Data())
                    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    request.timeoutInterval = 60
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    try Runner.check(response, nil)
                    stream.yield(.connected)
                    var parser = EventParser()
                    var line = Data()
                    // Newlines only, as the iPhone splits them (apps/shared/Runner.swift).
                    for try await byte in bytes {
                        guard byte == 0x0A else { line.append(byte); continue }
                        if let event = parser.feed(String(decoding: line, as: UTF8.self)) { stream.yield(event) }
                        line.removeAll(keepingCapacity: true)
                    }
                    stream.finish()
                } catch {
                    stream.finish(throwing: error)
                }
            }
            stream.onTermination = { _ in task.cancel() }
        }
    }

    private func call<Answer: Decodable>(_ method: String, _ target: String, body: (any Encodable)? = nil, timeout: TimeInterval = 45) async throws -> Answer {
        let data = try body.map { try Runner.encoder.encode($0) } ?? Data()
        var request = try signed(method, target, body: data)
        request.timeoutInterval = timeout
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (answer, response) = try await URLSession.shared.data(for: request)
        try Runner.check(response, answer)
        return try Runner.decoder.decode(Answer.self, from: answer)
    }

    /// A request to `target` (path and query, no leading slash) with the Access service token and
    /// this watch's signature over exactly what the runner will see.
    private func signed(_ method: String, _ target: String, body: Data) throws -> URLRequest {
        guard let url = URL(string: "/" + target, relativeTo: pairing.url)?.absoluteURL,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw RunnerError(message: "The Watch API's address isn't right. Pair the watch again on your iPhone.")
        }
        let path = components.percentEncodedPath + (components.percentEncodedQuery.map { "?" + $0 } ?? "")
        let time = String(Int(Date.now.timeIntervalSince1970))
        let nonce = UUID().uuidString
        let hash = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
        let message = Data("oby-watch\n\(method)\n\(path)\n\(time)\n\(nonce)\n\(hash)".utf8)
        let signature = try Self.key().signature(for: message)
        var request = URLRequest(url: url)
        request.httpMethod = method
        // Planning waits for the brain, which can take up to about 20 seconds.
        request.timeoutInterval = 45
        if method != "GET" { request.httpBody = body }
        request.setValue(pairing.clientID, forHTTPHeaderField: "CF-Access-Client-Id")
        request.setValue(pairing.clientSecret, forHTTPHeaderField: "CF-Access-Client-Secret")
        request.setValue(pairing.watch, forHTTPHeaderField: "Oby-Watch")
        request.setValue(time, forHTTPHeaderField: "Oby-Time")
        request.setValue(nonce, forHTTPHeaderField: "Oby-Nonce")
        request.setValue(signature.derRepresentation.base64EncodedString(), forHTTPHeaderField: "Oby-Signature")
        return request
    }
}

extension Glance {
    /// What the complications show for these jobs, as Home counts them: what needs you (that
    /// finished in the last week, as the iPhone trims it), what's working and what waits its turn (#238).
    nonisolated static func of(_ jobs: [Job], now: Date = .now) -> Glance {
        let needing = jobs.filter { $0.needsYou && ($0.finished ?? now) > now.addingTimeInterval(-7 * 86400) }
        return Glance(needs: needing.count, working: jobs.count(where: \.isWorking), waiting: jobs.count(where: \.isWaiting),
                      top: needing.first?.heading)
    }

    /// The complications' WidgetKit push token, as issued and as the runner accepted it, in the
    /// app group the widget and the app share.
    nonisolated static var widgetToken: WidgetToken {
        get { defaults?.data(forKey: "widgetToken").flatMap { try? JSONDecoder().decode(WidgetToken.self, from: $0) } ?? WidgetToken() }
        set { defaults?.set(try? JSONEncoder().encode(newValue), forKey: "widgetToken") }
    }

    /// WidgetKit issued or rotated the complications' token.
    nonisolated static func issued(_ token: Data) {
        var saved = widgetToken
        saved.issued = token
        widgetToken = saved
    }

    /// Hands the runner the complications' token if it hasn't accepted the latest one, trying
    /// `attempts` times, a little longer between each. The widget does it when the token changes,
    /// the app whenever it runs, so a token that couldn't go now goes later.
    nonisolated static func uploadWidgetToken(_ link: WatchLink, attempts: Int) async -> Bool {
        await WidgetToken.deliver(attempts: attempts, current: { widgetToken }, accept: { token in
            var saved = widgetToken
            if saved.issued == token { saved.accept(token) }
            widgetToken = saved
        }, send: { token in
            _ = try await link.registerPush(token, kind: "widget", topic: appTopic)
        }, wait: { failures in
            try? await Task.sleep(for: .seconds(2 * failures))
        })
    }

    /// The watch app's bundle ID, the topic WidgetKit pushes go to: the app's own when it runs
    /// (it saves it for the widget), else the widget extension's without its last part.
    nonisolated static var appTopic: String {
        get {
            if let saved = defaults?.string(forKey: "appTopic") { return saved }
            let own = Bundle.main.bundleIdentifier ?? ""
            return own.hasSuffix(".widget") ? String(own.dropLast(".widget".count)) : own
        }
        set { defaults?.set(newValue, forKey: "appTopic") }
    }
}

/// The app's and the widget's keychain items, in the app group both share, so the widget can
/// sign too. Generic passwords, this device only.
private nonisolated enum Keychain {
    static var group: String? { Bundle.main.object(forInfoDictionaryKey: "ObyAppGroup") as? String }

    static func query(_ account: String) -> [String: Any] {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: "com.deskree.oby.watch",
                                    kSecAttrAccount as String: account]
        if let group { query[kSecAttrAccessGroup as String] = group }
        return query
    }

    static func read(_ account: String) -> Data? {
        var query = query(account)
        query[kSecReturnData as String] = true
        var found: CFTypeRef?
        return SecItemCopyMatching(query as CFDictionary, &found) == errSecSuccess ? found as? Data : nil
    }

    static func write(_ data: Data, as account: String) throws {
        delete(account)
        var add = query(account)
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw RunnerError(message: "Couldn't keep the pairing on this watch (\(status)).") }
    }

    static func delete(_ account: String) {
        SecItemDelete(query(account) as CFDictionary)
    }
}
