import _CryptoExtras
import Crypto
import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import Testing
@testable import ObyEngine
@testable import oby_runner

/// The Cloudflare team's signing key and the Access application, as the tests' Cloudflare. The
/// key takes a moment to make: main-actor suites get it with `await TestAccess.ready()`, so they
/// don't hold up the main actor other suites time things on.
nonisolated enum TestAccess {
    static let key = try! _RSA.Signing.PrivateKey(keySize: .bits2048)

    static func ready() async {
        await Task.detached { _ = config }.value
    }
    static let audience = "4714c1358e65fe4b408ad6d432a5f878f08194bdb4752441fd56faefa9b2b6f2"
    /// A made-up service token, built at runtime so this file holds no line the scan would flag.
    static let fakeID = ["0123456789abcdef", "access"].joined(separator: ".")
    static let fakeSecret = String(repeating: "f00d", count: 8)
    static let fakeShortSecret = String(repeating: "f00d", count: 4)

    static func jwk(_ key: _RSA.Signing.PrivateKey, kid: String) -> AccessConfig.Key {
        let primitives = try! key.publicKey.getKeyPrimitives()
        return AccessConfig.Key(kid: kid, kty: "RSA", alg: "RS256", n: Push.base64URL(primitives.modulus), e: Push.base64URL(primitives.publicExponent))
    }

    static let config = AccessConfig(url: URL(string: "https://oby-watch.example.com")!, team: "example", audience: audience,
                                     keys: [jwk(key, kid: "k1")])

    /// What Access puts in `Cf-Access-Jwt-Assertion` for a service token, with `changes` made to its claims.
    static func jwt(now: Date = .now, header: [String: Any] = ["alg": "RS256", "kid": "k1", "typ": "JWT"], _ changes: [String: Any?] = [:]) -> String {
        var claims: [String: Any] = ["aud": [audience], "iss": "https://example.cloudflareaccess.com", "common_name": "abc123.access",
                                     "iat": Int(now.timeIntervalSince1970), "nbf": Int(now.timeIntervalSince1970),
                                     "exp": Int(now.timeIntervalSince1970) + 86400, "type": "app", "sub": ""]
        for (name, value) in changes { claims[name] = value }
        let input = Push.base64URL(try! JSONSerialization.data(withJSONObject: header, options: .sortedKeys)) + "."
            + Push.base64URL(try! JSONSerialization.data(withJSONObject: claims, options: .sortedKeys))
        let signature = try! key.signature(for: Data(input.utf8), padding: .insecurePKCS1v1_5)
        return input + "." + Push.base64URL(signature.rawRepresentation)
    }

    /// `watch.json` as the owner writes it.
    static func write(to file: URL) throws {
        let jwk = config.keys[0]
        let json: [String: Any] = ["url": config.url.absoluteString, "team": config.team, "audience": audience,
                                   "keys": [["kid": jwk.kid, "kty": jwk.kty, "alg": "RS256", "n": jwk.n, "e": jwk.e]]]
        try JSONSerialization.data(withJSONObject: json).write(to: file)
    }
}

struct AccessTokenTests {
    let now = Date(timeIntervalSince1970: 1_791_582_173)

    func refusal(_ token: String) -> String? {
        do {
            try AccessToken.check(token, config: TestAccess.config, now: now)
            return nil
        } catch {
            return (error as? AccessToken.Failure)?.reason ?? "\(error)"
        }
    }

    @Test func aTokenAccessSignedForThisApplicationPasses() {
        #expect(refusal(TestAccess.jwt(now: now)) == nil)
        // Access may send the audience as one string.
        #expect(refusal(TestAccess.jwt(now: now, ["aud": TestAccess.audience])) == nil)
    }

    @Test func anotherApplicationsAudienceFails() {
        #expect(refusal(TestAccess.jwt(now: now, ["aud": ["someone-elses-app"]])) == "is for another application")
        #expect(refusal(TestAccess.jwt(now: now, ["aud": nil])) == "is for another application")
    }

    @Test func anotherTeamFails() {
        #expect(refusal(TestAccess.jwt(now: now, ["iss": "https://evil.cloudflareaccess.com"])) == "comes from another team")
    }

    @Test func anExpiredOrFutureTokenFails() {
        #expect(refusal(TestAccess.jwt(now: now, ["exp": Int(now.timeIntervalSince1970) - 61])) == "has expired")
        #expect(refusal(TestAccess.jwt(now: now, ["exp": nil])) == "has expired")
        #expect(refusal(TestAccess.jwt(now: now, ["nbf": Int(now.timeIntervalSince1970) + 600])) == "isn't valid yet")
        // A minute of clock difference is fine.
        #expect(refusal(TestAccess.jwt(now: now, ["exp": Int(now.timeIntervalSince1970) - 30])) == nil)
    }

    @Test func onlyTheTeamsKeysSign() {
        #expect(refusal(TestAccess.jwt(now: now, header: ["alg": "RS256", "kid": "unknown"])) == "isn't signed by one of the team's keys")
        #expect(refusal(TestAccess.jwt(now: now, header: ["alg": "RS256"])) == "isn't signed by one of the team's keys")
    }

    @Test func noneAndSharedSecretAlgorithmsFail() {
        let token = TestAccess.jwt(now: now)
        let parts = token.split(separator: ".")
        for alg in ["none", "HS256", "ES256"] {
            let header = Push.base64URL(try! JSONSerialization.data(withJSONObject: ["alg": alg, "kid": "k1"]))
            #expect(refusal("\(header).\(parts[1]).\(parts[2])") == "isn't signed with RS256")
            #expect(refusal("\(header).\(parts[1]).") == "isn't signed with RS256")
        }
    }

    @Test func aChangedClaimBreaksTheSignature() {
        let token = TestAccess.jwt(now: now)
        let parts = token.split(separator: ".")
        let forged = TestAccess.jwt(now: now, ["common_name": "someone-else.access"]).split(separator: ".")[1]
        #expect(refusal("\(parts[0]).\(forged).\(parts[2])") == "has a signature that doesn't match")
        #expect(refusal("not a jwt") == "isn't a JWT")
        #expect(refusal("") == "isn't a JWT")
    }

    @Test func watchJSONIsReadAgainWhenItChanges() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = AccessFile(file: folder.appending(path: "watch.json"))
        #expect(file.config == nil)
        try TestAccess.write(to: file.file)
        #expect(file.config == TestAccess.config)
        // Keys rotated: the owner pastes the new list; the next request reads it.
        try Data(#"{"url": "https://oby-watch.example.com", "team": "example", "audience": "a", "keys": []}"#.utf8).write(to: file.file)
        try FileManager.default.setAttributes([.modificationDate: Date.now.addingTimeInterval(5)], ofItemAtPath: file.file.path)
        #expect(file.config == nil)
    }
}

@MainActor
final class WatchesTests {
    let folder: URL
    let vault: Vault
    let watches: Watches
    let key = P256.Signing.PrivateKey()
    let now = Date(timeIntervalSince1970: 1_791_582_173)

    init() throws {
        folder = try temporaryFolder()
        vault = Vault(store: FileVault(folder: folder.appending(path: "vault")))
        watches = Watches(file: folder.appending(path: "watches.json"), vault: vault)
    }

    deinit { try? FileManager.default.removeItem(at: folder) }

    func pair(_ key: P256.Signing.PrivateKey? = nil) throws -> String {
        try watches.pair(name: "Test Watch", publicKey: (key ?? self.key).publicKey.x963Representation.base64EncodedString(),
                         clientID: TestAccess.fakeID, clientSecret: TestAccess.fakeSecret, now: now)
    }

    func signed(_ watch: String, method: String = "GET", target: String = "/v1/jobs", time: Date? = nil,
                nonce: String = "n0nce-0123456789abc", body: Data = Data(), signedBody: Data? = nil, key: P256.Signing.PrivateKey? = nil) throws -> Watches.Signed {
        let time = String(Int((time ?? now).timeIntervalSince1970))
        let signature = try (key ?? self.key).signature(for: Watches.message(method: method, target: target, time: time, nonce: nonce, body: signedBody ?? body))
        return Watches.Signed(watch: watch, method: method, target: target, time: time, nonce: nonce,
                              signature: signature.derRepresentation.base64EncodedString(), body: body)
    }

    func refusal(_ request: Watches.Signed, at time: Date? = nil) -> HTTPResponse.Status? {
        do {
            _ = try watches.check(request, now: time ?? now)
            return nil
        } catch {
            return (error as? APIError)?.status
        }
    }

    @Test func aFreshRequestSignedByAPairedWatchPasses() throws {
        let watch = try pair()
        #expect(refusal(try signed(watch, method: "POST", target: "/v1/plans", body: Data(#"{"said":"hi"}"#.utf8))) == nil)
    }

    @Test func theSameRequestTwiceFails() throws {
        let watch = try pair()
        let request = try signed(watch)
        #expect(refusal(request) == nil)
        #expect(refusal(request) == .unauthorized)
        #expect(refusal(request, at: now + 100) == .unauthorized)
        // A new nonce is a new request.
        #expect(refusal(try signed(watch, nonce: "an0ther-n0nce-0123")) == nil)
    }

    @Test func aReplayAfterARestartFails() throws {
        let watch = try pair()
        // Signed a little ahead of the runner's clock, as a watch's clock may be.
        let request = try signed(watch, time: now + 4)
        #expect(refusal(request) == nil)
        // The used nonces outlive the process: the same request fails after a restart, anywhere in its window.
        for later in [now + 1, now + 60, now + 120] {
            let restarted = Watches(file: folder.appending(path: "watches.json"), vault: vault)
            #expect(throws: APIError.self) { try restarted.check(request, now: later) }
        }
        let restarted = Watches(file: folder.appending(path: "watches.json"), vault: vault)
        #expect(throws: Never.self) { try restarted.check(try self.signed(watch, time: now + 10, nonce: "an0ther-n0nce-0123"), now: now + 10) }
    }

    @Test func requestsExpireAfterTwoMinutesAndCantBeSignedAhead() throws {
        let watch = try pair()
        #expect(refusal(try signed(watch, time: now - 121, nonce: "aaaaaaaaaaaaaaaa1")) == .unauthorized)
        #expect(refusal(try signed(watch, time: now + 121, nonce: "aaaaaaaaaaaaaaaa2")) == .unauthorized)
        // A request from the future would outlive its nonce: only a few seconds of clock difference.
        #expect(refusal(try signed(watch, time: now + 6, nonce: "aaaaaaaaaaaaaaaa4")) == .unauthorized)
        #expect(refusal(try signed(watch, time: now + 5, nonce: "aaaaaaaaaaaaaaaa5")) == nil)
        #expect(refusal(try signed(watch, time: now - 119, nonce: "aaaaaaaaaaaaaaaa3")) == nil)
    }

    @Test func usedNoncesArePrivateAndGoOnceTheirWindowHasPassed() throws {
        let watch = try pair()
        #expect(refusal(try signed(watch, nonce: "first-n0nce-01234")) == nil)
        let mode = try FileManager.default.attributesOfItem(atPath: watches.noncesFile.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        #expect(String(decoding: try Data(contentsOf: watches.noncesFile), as: UTF8.self).contains("first-n0nce-01234"))
        // Two minutes on, the first can't get in anyway: the next request takes it off the file.
        #expect(refusal(try signed(watch, time: now + 121, nonce: "second-n0nce-0123"), at: now + 121) == nil)
        let kept = String(decoding: try Data(contentsOf: watches.noncesFile), as: UTF8.self)
        #expect(!kept.contains("first-n0nce-01234") && kept.contains("second-n0nce-0123"))
    }

    @Test func anUnreadableNoncesFileLetsNothingIn() throws {
        let watch = try pair()
        try Data("not json".utf8).write(to: watches.noncesFile)
        let restarted = Watches(file: folder.appending(path: "watches.json"), vault: vault)
        #expect(throws: APIError.self) { try restarted.check(try self.signed(watch), now: self.now) }
    }

    @Test func theSignatureCoversMethodPathAndBody() throws {
        let watch = try pair()
        var request = try signed(watch, method: "POST", target: "/v1/jobs/ab12/publish", body: Data(#"{"action":"Push a"}"#.utf8))
        request.body = Data(#"{"action":"Push b"}"#.utf8)
        #expect(refusal(request) == .unauthorized)
        request = try signed(watch, method: "GET", target: "/v1/jobs")
        request.target = "/v1/jobs/ab12"
        #expect(refusal(request) == .unauthorized)
        request = try signed(watch, method: "GET", target: "/v1/jobs")
        request.method = "POST"
        #expect(refusal(request) == .unauthorized)
    }

    @Test func onlyPairedWatchesKeysCount() throws {
        let watch = try pair()
        #expect(refusal(try signed(watch, key: P256.Signing.PrivateKey())) == .unauthorized)
        #expect(refusal(try signed("someone-else")) == .unauthorized)
        #expect(refusal(try signed(watch, nonce: "short")) == .unauthorized)
    }

    @Test func pairingKeepsTheServiceTokenInTheVault() throws {
        let watch = try pair()
        #expect(try vault.names() == [Watches.VaultEntry.idEntry, Watches.VaultEntry.tokenEntry].sorted())
        #expect(try vault.use(Watches.VaultEntry.tokenEntry) { $0 } == TestAccess.fakeSecret)
        // The secret scan knows it now: nothing outgoing carries it.
        #expect(try vault.leaks().redact("token \(TestAccess.fakeSecret)") != "token \(TestAccess.fakeSecret)")
        // The file has no token, only the Watch's public key.
        let saved = String(decoding: try Data(contentsOf: folder.appending(path: "watches.json")), as: UTF8.self)
        #expect(!saved.contains(TestAccess.fakeSecret) && saved.contains(watch))
        // The same key pairs again with the same id.
        #expect(try pair() == watch)
    }

    @Test func aRemovedWatchCanNoLongerAskAndTheLastTakesTheToken() throws {
        let watch = try pair()
        let second = try pair(P256.Signing.PrivateKey())
        try watches.remove(watch)
        #expect(refusal(try signed(watch)) == .unauthorized)
        #expect(try vault.names().count == 2)
        try watches.remove(second)
        #expect(try vault.names().isEmpty)
        #expect(throws: APIError.self) { try self.watches.remove(watch) }
        #expect(Watches(file: folder.appending(path: "watches.json"), vault: vault).watches.isEmpty)
    }

    @Test func pairingTakesOnlyAKeyAndAToken() {
        #expect(throws: APIError.self) {
            try self.watches.pair(name: "Watch", publicKey: "bm90IGEga2V5", clientID: TestAccess.fakeID, clientSecret: TestAccess.fakeShortSecret, now: self.now)
        }
        #expect(throws: APIError.self) {
            try self.watches.pair(name: "Watch", publicKey: self.key.publicKey.x963Representation.base64EncodedString(),
                                  clientID: "short", clientSecret: TestAccess.fakeShortSecret, now: self.now)
        }
    }
}

/// The Watch API over HTTP: the gate, the endpoints, pairing from the phone, and push tokens.
@MainActor
final class WatchAPITests {
    let folder: URL
    let owner: HTTPFields = [.tailscaleUserLogin: "well@example.com"]
    let watchKey = P256.Signing.PrivateKey()
    let phoneKey = P256.Signing.PrivateKey()
    let vault: Vault
    let devices: Devices
    let watches: Watches
    let access: AccessFile

    init() async throws {
        await TestAccess.ready()
        folder = try temporaryFolder()
        vault = Vault(store: FileVault(folder: folder.appending(path: "vault")))
        devices = Devices(file: folder.appending(path: "devices.json"))
        watches = Watches(file: folder.appending(path: "watches.json"), vault: vault)
        access = AccessFile(file: folder.appending(path: "watch.json"))
        try TestAccess.write(to: access.file)
    }

    deinit { try? FileManager.default.removeItem(at: folder) }

    func watchAPI(push: Bool = false) throws -> WatchAPI {
        let desk = Desk(accounts: AccountStore(root: folder), store: JobStore(url: folder.appending(path: "oby.sqlite")))
        var pusher: Push?
        if push {
            let apns = folder.appending(path: "apns")
            try FileManager.default.createDirectory(at: apns, withIntermediateDirectories: true)
            try Data(#"{"team": "TEAM123456", "key": "KEY1234567"}"#.utf8).write(to: apns.appending(path: "apns.json"))
            try P256.Signing.PrivateKey().pemRepresentation.write(to: apns.appending(path: "AuthKey_KEY1234567.p8"), atomically: true, encoding: .utf8)
            pusher = Push(desk: desk, folder: apns)
        }
        return WatchAPI(api: API(desk: desk, devices: devices, push: pusher), watches: watches, access: access)
    }

    func pairWatch() throws -> String {
        try watches.pair(name: "Test Watch", publicKey: watchKey.publicKey.x963Representation.base64EncodedString(),
                         clientID: TestAccess.fakeID, clientSecret: TestAccess.fakeSecret)
    }

    /// The headers a request through the tunnel carries: Access's JWT and the Watch's signature.
    nonisolated func headers(_ watch: String, _ method: String, _ target: String, body: Data = Data(), jwt: String? = TestAccess.jwt(),
                 nonce: String = UUID().uuidString, key: P256.Signing.PrivateKey? = nil) throws -> HTTPFields {
        let time = String(Int(Date.now.timeIntervalSince1970))
        let signature = try (key ?? watchKey).signature(for: Watches.message(method: method, target: target, time: time, nonce: nonce, body: body))
        var fields: HTTPFields = [.obyWatch: watch, .obyTime: time, .obyNonce: nonce, .obySignature: signature.derRepresentation.base64EncodedString()]
        if let jwt { fields[.cfAccessJwtAssertion] = jwt }
        return fields
    }

    @Test func theTailnetLoginOpensNothing() async throws {
        let app = Application(router: try watchAPI().router())
        try await app.test(.router) { [owner] client in
            try await client.execute(uri: "/v1/jobs", method: .get, headers: owner) { response in
                #expect(response.status == .unauthorized)
            }
        }
    }

    @Test func bothTheAccessTokenAndTheSignatureAreNeeded() async throws {
        let watch = try pairWatch()
        let app = Application(router: try watchAPI().router())
        try await app.test(.router) { client in
            // No JWT.
            try await client.execute(uri: "/v1/jobs", method: .get, headers: try headers(watch, "GET", "/v1/jobs", jwt: nil)) { response in
                #expect(response.status == .unauthorized)
            }
            // A JWT for another application.
            try await client.execute(uri: "/v1/jobs", method: .get,
                                     headers: try headers(watch, "GET", "/v1/jobs", jwt: TestAccess.jwt(["aud": ["other"]]))) { response in
                #expect(response.status == .unauthorized)
                #expect(String(buffer: response.body).contains("another application"))
            }
            // The JWT alone.
            try await client.execute(uri: "/v1/jobs", method: .get, headers: [.cfAccessJwtAssertion: TestAccess.jwt()]) { response in
                #expect(response.status == .unauthorized)
            }
            // Signed by a key that isn't paired.
            try await client.execute(uri: "/v1/jobs", method: .get,
                                     headers: try headers(watch, "GET", "/v1/jobs", key: P256.Signing.PrivateKey())) { response in
                #expect(response.status == .unauthorized)
            }
            // Both: the jobs.
            try await client.execute(uri: "/v1/jobs?limit=5", method: .get, headers: try headers(watch, "GET", "/v1/jobs?limit=5")) { response in
                #expect(response.status == .ok)
                #expect(String(buffer: response.body) == "[]")
            }
            // Paths the Watch API doesn't serve are refused before anything else.
            try await client.execute(uri: "/v1/status", method: .get, headers: [:]) { response in
                #expect(response.status == .unauthorized)
            }
        }
    }

    @Test func aReplayedRequestFails() async throws {
        let watch = try pairWatch()
        let app = Application(router: try watchAPI().router())
        try await app.test(.router) { client in
            let body = ByteBuffer(string: #"{"text": "also run the tests"}"#)
            let signed = try headers(watch, "POST", "/v1/jobs/ab12cd34/messages", body: Data(body.readableBytesView))
            try await client.execute(uri: "/v1/jobs/ab12cd34/messages", method: .post, headers: signed, body: body) { response in
                // Through the gate: the runner just has no such job.
                #expect(response.status == .notFound)
            }
            try await client.execute(uri: "/v1/jobs/ab12cd34/messages", method: .post, headers: signed, body: body) { response in
                #expect(response.status == .unauthorized)
                #expect(String(buffer: response.body).contains("already used"))
            }
        }
    }

    @Test func withoutWatchJSONNothingGetsIn() async throws {
        let watch = try pairWatch()
        try FileManager.default.removeItem(at: access.file)
        let app = Application(router: try watchAPI().router())
        try await app.test(.router) { client in
            try await client.execute(uri: "/v1/jobs", method: .get, headers: try headers(watch, "GET", "/v1/jobs")) { response in
                #expect(response.status == .serviceUnavailable)
            }
        }
    }

    @Test func speechIsTakenButNotWrittenDownYet() async throws {
        let watch = try pairWatch()
        let app = Application(router: try watchAPI().router())
        try await app.test(.router) { client in
            let piece = ByteBuffer(bytes: [UInt8](repeating: 1, count: 8000))
            let target = "/v1/speech?request=0f6b2c1e-hold&sequence=0"
            try await client.execute(uri: target, method: .post, headers: try headers(watch, "POST", target, body: Data(piece.readableBytesView)), body: piece) { response in
                #expect(response.status == .notImplemented)
                #expect(String(buffer: response.body).contains("Speech-to-text isn't set up"))
            }
            let odd = ByteBuffer(bytes: [1, 2, 3])
            try await client.execute(uri: target, method: .post, headers: try headers(watch, "POST", target, body: Data(odd.readableBytesView)), body: odd) { response in
                #expect(response.status == .unprocessableContent)
            }
            let bad = "/v1/speech?sequence=0"
            try await client.execute(uri: bad, method: .post, headers: try headers(watch, "POST", bad, body: Data(piece.readableBytesView)), body: piece) { response in
                #expect(response.status == .badRequest)
            }
        }
    }

    @Test func theWatchRegistersItsOwnPushTokens() async throws {
        let watch = try pairWatch()
        let api = try watchAPI(push: true)
        let app = Application(router: api.router())
        try await app.test(.router) { client in
            for (kind, token) in [("alert", "aa11bb22cc33dd44"), ("widget", "ee55ff66aa77bb88")] {
                let body = ByteBuffer(string: #"{"token": "\#(token)", "topic": "dev.wellprado.oby.watchkitapp", "environment": "development", "kind": "\#(kind)"}"#)
                try await client.execute(uri: "/v1/notifications", method: .post,
                                         headers: try headers(watch, "POST", "/v1/notifications", body: Data(body.readableBytesView)), body: body) { response in
                    #expect(response.status == .ok)
                    #expect(object(Data(response.body.readableBytesView))["push"] as? Bool == true)
                }
            }
        }
        let tokens = try #require(api.api.push).tokens
        #expect(tokens.map(\.kind) == ["alert", "widget"])
        #expect(tokens.allSatisfy { $0.watch == watch })
    }

    @Test func thePhonePairsListsAndRemovesAWatch() async throws {
        let api = try watchAPI(push: true)
        FileManager.default.createFile(atPath: devices.pairing.path, contents: nil)
        let phone = try devices.register(name: "Test iPhone", publicKey: phoneKey.publicKey.x963Representation.base64EncodedString())
        let router = api.api.router(owner: "well@example.com")
        api.pairing(on: router)
        let publicKey = watchKey.publicKey.x963Representation.base64EncodedString()
        let pairing = { @Sendable [phoneKey] (signedAt: Date, key: P256.Signing.PrivateKey?) throws -> ByteBuffer in
            let signedAt = signedAt.formatted(.iso8601)
            let signature = try (key ?? phoneKey).signature(for: Data("oby-pair-watch\n\(publicKey)\n\(signedAt)".utf8))
            let body: [String: Any] = ["name": "Wellington's Apple Watch", "publicKey": publicKey,
                                       "accessClientId": TestAccess.fakeID, "accessClientSecret": TestAccess.fakeSecret,
                                       "approval": ["device": phone, "signedAt": signedAt, "signature": signature.derRepresentation.base64EncodedString()]]
            return ByteBuffer(bytes: try JSONSerialization.data(withJSONObject: body))
        }
        let app = Application(router: router)
        let watch: String = try await app.test(.router) { [owner] client in
            // Only the owner.
            try await client.execute(uri: "/v1/watches", method: .post, headers: [:], body: try pairing(.now, nil)) { response in
                #expect(response.status == .unauthorized)
            }
            // Only with the phone's Face ID approval of this key.
            try await client.execute(uri: "/v1/watches", method: .post, headers: owner, body: try pairing(.now, P256.Signing.PrivateKey())) { response in
                #expect(response.status == .forbidden)
            }
            try await client.execute(uri: "/v1/watches", method: .post, headers: owner, body: try pairing(.now - 300, nil)) { response in
                #expect(response.status == .forbidden)
            }
            #expect(try self.vault.names().isEmpty)
            let body = try pairing(.now, nil)
            let id: String = try await client.execute(uri: "/v1/watches", method: .post, headers: owner, body: body) { response in
                #expect(response.status == .created)
                let answer = object(Data(response.body.readableBytesView))
                #expect(answer["url"] as? String == "https://oby-watch.example.com")
                return answer["id"] as? String ?? ""
            }
            // The approval works once.
            try await client.execute(uri: "/v1/watches", method: .post, headers: owner, body: body) { response in
                #expect(response.status == .forbidden)
            }
            try await client.execute(uri: "/v1/watches", method: .get, headers: owner) { response in
                let text = String(buffer: response.body)
                #expect(text.contains(id) && text.contains("Wellington's Apple Watch"))
                #expect(!text.contains(publicKey) && !text.contains(TestAccess.fakeSecret))
            }
            return id
        }
        #expect(try vault.names().count == 2)
        let push = try #require(api.api.push)
        _ = try push.register(Push.Token(token: "aa11bb22cc33dd44", kind: "alert", topic: "dev.wellprado.oby.watchkitapp", environment: "development", watch: watch))
        _ = try push.register(Push.Token(token: "1234abcd1234abcd", kind: "alert", topic: "dev.wellprado.oby", environment: "development"))

        // The Watch can use the Watch API now; once removed, it can't.
        let watchApp = Application(router: api.router())
        try await watchApp.test(.router) { client in
            try await client.execute(uri: "/v1/jobs", method: .get, headers: try headers(watch, "GET", "/v1/jobs")) { response in
                #expect(response.status == .ok)
            }
        }
        try await app.test(.router) { [owner] client in
            try await client.execute(uri: "/v1/watches/\(watch)", method: .delete, headers: owner) { response in
                #expect(response.status == .ok)
            }
            try await client.execute(uri: "/v1/watches/\(watch)", method: .delete, headers: owner) { response in
                #expect(response.status == .notFound)
            }
        }
        try await watchApp.test(.router) { client in
            try await client.execute(uri: "/v1/jobs", method: .get, headers: try headers(watch, "GET", "/v1/jobs")) { response in
                #expect(response.status == .unauthorized)
            }
        }
        // Its push token went with it; the phone's stays. So did the service token.
        #expect(push.tokens.map(\.token) == ["1234abcd1234abcd"])
        #expect(try vault.names().isEmpty)
    }

    @Test func pairingNeedsTheWatchAPISetUp() throws {
        try FileManager.default.removeItem(at: access.file)
        let api = try watchAPI()
        let approval = PairingApproval(device: "d", signedAt: "2026-10-11T00:00:00Z", signature: "")
        #expect(throws: APIError.self) {
            try api.pair(NewWatch(name: "Watch", publicKey: "", accessClientId: "", accessClientSecret: "", approval: approval))
        }
    }
}

@MainActor
final class WatchPushTests {
    let folder: URL

    init() throws {
        folder = try temporaryFolder()
    }

    deinit { try? FileManager.default.removeItem(at: folder) }

    func push() throws -> Push {
        let desk = Desk(accounts: AccountStore(root: folder), store: JobStore(url: folder.appending(path: "oby.sqlite")))
        try Data(#"{"team": "TEAM123456", "key": "KEY1234567"}"#.utf8).write(to: folder.appending(path: "apns.json"))
        try P256.Signing.PrivateKey().pemRepresentation.write(to: folder.appending(path: "AuthKey_KEY1234567.p8"), atomically: true, encoding: .utf8)
        return Push(desk: desk, folder: folder)
    }

    let phone = Push.Token(token: "1234abcd1234abcd", kind: "alert", topic: "dev.wellprado.oby", environment: "production")
    let watchAlert = Push.Token(token: "aa11bb22cc33dd44", kind: "alert", topic: "dev.wellprado.oby.watchkitapp", environment: "production", watch: "w1")
    let widget = Push.Token(token: "ee55ff66aa77bb88", kind: "widget", topic: "dev.wellprado.oby.watchkitapp", environment: "production", watch: "w1")
    let activity = Push.Token(token: "99887766554433221100", kind: "update", topic: "dev.wellprado.oby", environment: "production")

    @Test func theWatchAndThePhoneGetTheSameAlert() throws {
        var failed = job
        failed.status = .failed
        failed.summary = "The check failed."
        let deliveries = Push.alerts([(failed, .failed)], to: [phone, watchAlert, widget, activity])
        #expect(deliveries.map(\.token) == [phone, watchAlert])
        // One payload, one collapse ID: the Watch shows it once.
        #expect(Set(deliveries.map(\.body)).count == 1)
        #expect(deliveries.allSatisfy { $0.type == "alert" && $0.priority == 10 && $0.collapse == failed.id })
        let alert = object(deliveries[0].body)
        #expect(alert["job"] as? String == failed.id)
        // And both clear together.
        let cleared = Push.alerts([(failed, nil)], to: [phone, watchAlert])
        #expect(cleared.allSatisfy { $0.type == "background" && $0.collapse == nil })
    }

    @Test func theComplicationsGetAWidgetKitPush() throws {
        let deliveries = Push.complications(to: [phone, watchAlert, widget, activity])
        #expect(deliveries.map(\.token) == [widget])
        #expect(deliveries[0].type == "widgets")
        #expect(String(decoding: deliveries[0].body, as: UTF8.self) == #"{"aps":{"content-changed":true}}"#)
    }

    @Test func theComplicationsCountWhatNeedsYouAndWhatsWorking() {
        var failed = job
        failed.status = .failed
        var running = job
        running.id = "running1"
        running.status = .running
        var done = job
        done.id = "done1"
        done.status = .done
        #expect(Push.glance([failed, running, done]) == Push.Glance(needs: 1, working: 1))
        #expect(Push.glance([]) == Push.Glance(needs: 0, working: 0))
    }

    @Test func aWatchKeepsOneWidgetTokenAndUnpairingDropsItsTokens() throws {
        let push = try push()
        #expect(try push.register(phone))
        #expect(try push.register(watchAlert))
        #expect(try push.register(widget))
        var newer = widget
        newer.token = "0011223344556677"
        #expect(try push.register(newer))
        #expect(push.tokens.filter { $0.kind == "widget" }.map(\.token) == ["0011223344556677"])
        push.forget(watch: "w1")
        #expect(push.tokens == [phone])
        // Kept across restarts, with the Watch each came from.
        #expect(try push.register(watchAlert))
        let reread = try self.push()
        #expect(reread.tokens.last?.watch == "w1")
    }

    @Test func thePhonesActivityEndpointTakesNoWatchTokens() async throws {
        let desk = Desk(accounts: AccountStore(root: folder), store: JobStore(url: folder.appending(path: "oby.sqlite")))
        let api = API(desk: desk, devices: Devices(file: folder.appending(path: "devices.json")), push: try push())
        #expect(throws: APIError.self) { try api.activity(self.widget) }
        _ = try api.activity(Push.Token(token: "99887766554433221100", kind: "update", topic: "dev.wellprado.oby", environment: "production", watch: "w1"))
        #expect(api.push?.tokens.last?.watch == nil)
    }
}
