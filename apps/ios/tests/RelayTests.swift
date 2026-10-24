import CryptoKit
import Foundation
import Testing
@testable import Oby

/// The iPhone's side of the phone relay (#1278, apps/shared/PhoneRelay.swift): the envelope's known
/// answer from docs/runner-api.md, byte for byte, its refusals, and requests, the event stream and
/// pairing through a fake Obysphere whose Mac answers as obid's relay does.
@MainActor
struct RelayTests {
    // MARK: The known answer (docs/runner-api.md, "The envelope (version 1)")

    static let macPublic = "8f40c5adb68f25624ae5b214ea767a6ec94d829d3d7b5e1ad1ba6f3e2138285f"
    static let hello = "0101358072d6365880d1aeea329adf9121383851ed21a28e3b75e965d0d2cd166254a2b39ce6bc8467ffdd094cfa4ea2258b59"
    static let welcome = "010279a631eede1bf9c98f12032cdeadd0e7a079398fc786b88cc846ec89af85a51a0944396b30ca3b9834e5d232b1f803e05b"
    static let request = "01030000000000000000f5727141453120bc5930b45fc6041dd63ff38849669a6597b32e0126a0a47e5b8fe24aa92a12c8cb0b0d802d00b9b406da400b17143ce5eb2c2ec1d382aea99104e3927783310d114581bd85e058d1ebfe3852a2b3daf14baac186d5bb8a9459923c8d5f80fc14bc380ab04ace824f10"
    static let answer = [
        "010300000000000000000a35fcb1ed7cde7ec716ca66cb4bfe2f07395d39e87ad3465de5430d568548a6ff91920033e8ba5f0286bafa8e7381285da738f3788c0b3889dd22cf8b188f542334f708ec77c3267f435ac2e4c58b4d64",
        "0103000000000000000104872ef5d6738d2ec970fec24a408375a3ad546947fe63f62b4aac3868fe9137",
        "010300000000000000020715d08c652dc9cad1f99f67006dbe715414875ed5",
    ]
    static let asked = RelayFrame(stream: 1, kind: .open, payload: Data(#"{"method":"GET","path":"/v1/status","headers":{"authorization":"Bearer test-device-token"}}"#.utf8))
    static let answered = [
        RelayFrame(stream: 1, kind: .open, payload: Data(#"{"status":200,"headers":{"content-type":"application/json"}}"#.utf8)),
        RelayFrame(stream: 1, kind: .data, payload: Data(#"{"ok":true}"#.utf8)),
        RelayFrame(stream: 1, kind: .end),
    ]

    /// The known answer's keys: bytes `from` to `from + 31`.
    static func key(_ from: UInt8) -> Curve25519.KeyAgreement.PrivateKey {
        try! .init(rawRepresentation: Data((from..<from + 32).map { $0 }))
    }

    /// The known answer's session: the Mac's and the phone's.
    func vector() throws -> (mac: RelayEnvelope.Session, phone: RelayEnvelope.Session) {
        let hello = try RelayEnvelope.Hello(to: Self.key(0).publicKey.rawRepresentation, ephemeral: Self.key(32))
        let (_, mac) = try TestMac(agreement: Self.key(0)).welcome(hello.bytes, ephemeral: Self.key(64))
        return (mac, try hello.welcomed(unhex(Self.welcome)))
    }

    @Test func theEnvelopeGivesTheDocsKnownAnswer() throws {
        let mac = TestMac(agreement: Self.key(0))
        #expect(hex(mac.publicKey) == Self.macPublic)
        let hello = try RelayEnvelope.Hello(to: mac.publicKey, ephemeral: Self.key(32))
        #expect(hex(hello.bytes) == Self.hello)
        let (welcome, macSide) = try mac.welcome(hello.bytes, ephemeral: Self.key(64))
        #expect(hex(welcome) == Self.welcome)
        var phone = try hello.welcomed(unhex(Self.welcome))
        var macSession = macSide
        let request = phone.seal(Self.asked.encoded)
        #expect(hex(request) == Self.request)
        #expect(macSession.open(request) == .frame(Self.asked.encoded))
        for (sealed, frame) in zip(Self.answer, Self.answered) {
            #expect(hex(macSession.seal(frame.encoded)) == sealed)
            #expect(phone.open(unhex(sealed)) == .frame(frame.encoded))
        }
    }

    @Test func aChangedEnvelopeDoesntOpenAndSpendsNothing() throws {
        var (_, phone) = try vector()
        let sealed = unhex(Self.answer[0])
        // Every byte counts: the header and counter are the associated data, the rest ciphertext and tag.
        for at in sealed.indices {
            var changed = sealed
            changed[at] ^= 0x01
            #expect(phone.open(changed) == .dropped, "byte \(at)")
        }
        #expect(phone.open(sealed.dropLast()) == .dropped)
        #expect(phone.open(sealed) == .frame(Self.answered[0].encoded))
        // Nor does a changed welcome start a session.
        let hello = try RelayEnvelope.Hello(to: Self.key(0).publicKey.rawRepresentation, ephemeral: Self.key(32))
        for at in 2..<51 {
            var changed = unhex(Self.welcome)
            changed[at] ^= 0x01
            #expect(throws: RelayEnvelope.Refused.self, "welcome byte \(at)") { try hello.welcomed(changed) }
        }
    }

    @Test func aReplayedOrOlderEnvelopeIsDropped() throws {
        var (mac, phone) = try vector()
        #expect(phone.open(unhex(Self.answer[0])) == .frame(Self.answered[0].encoded))
        #expect(phone.open(unhex(Self.answer[1])) == .frame(Self.answered[1].encoded))
        #expect(phone.open(unhex(Self.answer[0])) == .dropped)
        #expect(phone.open(unhex(Self.answer[1])) == .dropped)
        // The phone's own envelope sent back to it opens under neither key.
        let mine = phone.seal(Data("to the Mac".utf8))
        #expect(phone.open(mine) == .dropped)
        #expect(mac.open(mine) == .frame(Data("to the Mac".utf8)))
    }

    @Test func aMissingEnvelopeEndsTheSession() throws {
        var (_, phone) = try vector()
        // The second answer before the first: one is missing, nothing skipped silently.
        #expect(phone.open(unhex(Self.answer[1])) == .gap)
        // A forged one past the next proves nothing.
        var forged = unhex(Self.answer[2])
        forged[20] ^= 0x01
        #expect(phone.open(forged) == .dropped)
        // Nothing was spent: the first is still the next.
        #expect(phone.open(unhex(Self.answer[0])) == .frame(Self.answered[0].encoded))
    }

    @Test func aDowngradeIsRefused() throws {
        var (_, phone) = try vector()
        // The version is the session's, under the tag.
        var older = unhex(Self.answer[0])
        older[0] = 0
        #expect(phone.open(older) == .dropped)
        // A welcome choosing a version this iPhone didn't offer, or one it offered but the Mac didn't seal.
        let mac = TestMac(agreement: Self.key(0))
        let hello = try RelayEnvelope.Hello(to: mac.publicKey)
        var welcome = try mac.welcome(hello.bytes).0
        welcome[0] = 2
        #expect(throws: RelayEnvelope.Refused.unreadable) { try hello.welcomed(welcome) }
        let offering = try RelayEnvelope.Hello(to: mac.publicKey, offering: [1, 2])
        var changed = try mac.welcome(offering.bytes).0
        changed[0] = 2
        #expect(throws: RelayEnvelope.Refused.notTheMac) { try offering.welcomed(changed) }
    }

    @Test func onlyThePinnedKeyAnswers() throws {
        let mac = TestMac(agreement: Self.key(0))
        let other = TestMac(agreement: Self.key(100))
        // Whoever answers without the pinned key (the Sphere, with one of its own) can't open the
        // hello, so its welcome is for a hello of its own, and it doesn't open.
        let hello = try RelayEnvelope.Hello(to: mac.publicKey)
        #expect(throws: (any Error).self) { try other.welcome(hello.bytes) }
        let forged = try other.welcome(try RelayEnvelope.Hello(to: other.publicKey).bytes).0
        #expect(throws: RelayEnvelope.Refused.notTheMac) { try hello.welcomed(forged) }
        // A key that isn't one agrees with nothing.
        #expect(throws: (any Error).self) { try RelayEnvelope.Hello(to: Data(count: 32)) }
    }

    // MARK: Through a fake Obysphere

    @Test func aRequestGoesSealedThroughTheSphere() async throws {
        let mac = FakeMac()
        let relay = mac.relay()
        let runner = Runner(base: RemoteRoute.relayBase, token: "device-token-1", relay: relay)
        mac.answer = { head, body in
            (200, Data(#"{"path":"\#(head.path)","body":"\#(String(decoding: body, as: UTF8.self))"}"#.utf8))
        }
        let answered = try await runner.send("POST", "v1/conversation?id=c1", json: Data(#"{"say":"hi"}"#.utf8))
        #expect(String(decoding: answered, as: UTF8.self) == #"{"path":"/v1/conversation?id=c1","body":"{"say":"hi"}"}"#)
        // The socket opens at the Sphere's relay with the relay token, never the device token.
        let socket = try #require(mac.sockets.first)
        #expect(socket.request.url?.absoluteString == "wss://sphere.example/v0.1/relay/\(FakeMac.relayID)")
        #expect(socket.request.value(forHTTPHeaderField: "Authorization") == "Bearer \(FakeMac.token)")
        // The Mac got the method, the path, the device token and the body, sealed.
        let head = try #require(mac.heads.first)
        #expect(head.method == "POST" && head.path == "/v1/conversation?id=c1")
        #expect(head.headers["authorization"] == "Bearer device-token-1")
        #expect(head.headers["content-type"] == "application/json")
        // What the Sphere carried is ciphertext: the device token and the words never appear in it.
        for message in socket.sent {
            guard case .data(let data) = message else { continue }
            #expect(data.range(of: Data("device-token-1".utf8)) == nil && data.range(of: Data("say".utf8)) == nil)
        }
        // A refusal is the gateway's, as over HTTP.
        mac.answer = { _, _ in (403, Data(#"{"error":"Not on this phone."}"#.utf8)) }
        await #expect(throws: RunnerError.self) { try await runner.send("GET", "v1/hooks") }
        #expect(mac.hellos == 1)
    }

    /// Requests at once each get their answer: their streams reach the Mac in order, each id above
    /// the last, and their envelopes with exact counters.
    @Test func manyRequestsAtOnceKeepTheirOrder() async throws {
        let mac = FakeMac()
        mac.answer = { head, _ in (200, Data(head.path.utf8)) }
        let runner = Runner(base: RemoteRoute.relayBase, token: "t", relay: mac.relay())
        let paths = try await withThrowingTaskGroup(of: (Int, String).self) { group in
            for n in 0..<20 {
                group.addTask { (n, String(decoding: try await runner.send("GET", "v1/jobs/\(n)"), as: UTF8.self)) }
            }
            return try await group.reduce(into: [:]) { $0[$1.0] = $1.1 }
        }
        #expect(paths.count == 20 && paths.allSatisfy { $0.value == "/v1/jobs/\($0.key)" })
        #expect(mac.hellos == 1)
    }

    @Test func theEventStreamComesSealedAndStopsWhenLeft() async throws {
        let mac = FakeMac()
        mac.streaming = Data("event: clear\ndata: {\"clearedAt\":\"2026-10-23T10:00:00Z\"}\n\n".utf8)
        let runner = Runner(base: RemoteRoute.relayBase, token: "device-token-1", relay: mac.relay())
        var events: [RunnerEvent] = []
        for try await event in runner.events() {
            events.append(event)
            if events.count == 2 { break }
        }
        #expect(events.first == .connected)
        if case .cleared = events.last {} else { Issue.record("no clear event: \(events)") }
        // Leaving the stream resets it at the Mac.
        for _ in 0..<50 where !mac.frames.contains(where: { $0.kind == .reset }) { try await Task.sleep(for: .milliseconds(20)) }
        #expect(mac.frames.contains { $0.kind == .reset && $0.stream == 1 })
    }

    @Test func pairingGoesThroughTheRelay() async throws {
        defer {
            GatewayTokenStore.remove()
            RelayStore.remove()
        }
        let mac = FakeMac()
        let relay = mac.relay()
        mac.answer = { _, _ in (200, Data(#"{"token":"tok-relay","expiresAt":"2026-11-22T10:00:00Z"}"#.utf8)) }
        let answer = try await GatewayPairing.redeem(at: RemoteRoute.relayBase, credential: "one-time", name: "Test iPhone") {
            try await relay.data(for: $0)
        }
        #expect(answer.token == "tok-relay")
        #expect(GatewayTokenStore.read() == "tok-relay")
        let head = try #require(mac.heads.first)
        #expect(head.method == "POST" && head.path == "/v1/pairing" && head.headers["authorization"] == nil)
        #expect(try JSONDecoder().decode([String: String].self, from: mac.bodies[0]) == ["credential": "one-time", "name": "Test iPhone"])
        // The relay, the token and the Mac's key with it, kept in the keychain alone.
        try RelayStore.save(mac.link)
        #expect(RelayStore.read() == mac.link)
        RelayStore.remove()
        #expect(RelayStore.read() == nil)
    }

    @Test func theQRCodeCarriesTheRelay() throws {
        let mac = FakeMac()
        let relay = String(decoding: try JSONEncoder().encode(mac.link), as: UTF8.self)
        let text = #"{"url":"https://sphere.example","link":{"hostname":"studio","name":"Studio","relay":\#(relay)},"secret":"s"}"#
        let envelope = try GatewayEnvelope.decode(text)
        #expect(envelope.relay == mac.link)
        #expect(envelope.link == MacLink(name: "Studio", hostname: "studio"))
        // An Obysphere over plain HTTP elsewhere than this device, or a field obid doesn't make, isn't paired with.
        var wrong = [mac.link, mac.link, mac.link, mac.link]
        wrong[0].sphere = URL(string: "http://sphere.example")!
        wrong[1].token = "short"
        wrong[2].key = String(mac.link.key.dropLast(2))
        wrong[3].id = "not/base64url/at/all/but/long/enough"
        for link in wrong {
            let relay = String(decoding: try JSONEncoder().encode(link), as: UTF8.self)
            #expect(throws: RunnerError.self) {
                try GatewayEnvelope.decode(#"{"url":"https://sphere.example","link":{"hostname":"studio","name":"Studio","relay":\#(relay)},"secret":"s"}"#)
            }
        }
        // A pasted one names its Mac plainly: a short hostname of letters, digits, dots and dashes,
        // a short name of one line.
        let relayed = String(decoding: try JSONEncoder().encode(mac.link), as: UTF8.self)
        for (hostname, name) in [("", "Studio"), ("studio/evil", "Studio"), (String(repeating: "a", count: 254), "Studio"),
                                 ("studio:", "Studio"), ("studio:123456", "Studio"), ("studio:84a3", "Studio"), (":8443", "Studio"),
                                 ("studio", ""), ("studio", "Studio\nPay here"), ("studio", String(repeating: "n", count: 65))] {
            let link = String(decoding: try JSONEncoder().encode(["hostname": hostname, "name": name]), as: UTF8.self).dropLast()
            #expect(throws: RunnerError.self, Comment(rawValue: "\(hostname) \(name)")) {
                try GatewayEnvelope.decode(#"{"url":"https://sphere.example","link":\#(link),"relay":\#(relayed)},"secret":"s"}"#)
            }
        }
        for hostname in ["Wellingtons-MacBook-Pro.local", "studio.tail0000.ts.net:8443"] {
            #expect((try? GatewayEnvelope.decode(#"{"url":"https://sphere.example","link":{"hostname":"\#(hostname)","name":"Wellington's MacBook Air","relay":\#(relayed)},"secret":"s"}"#)) != nil,
                    Comment(rawValue: hostname))
        }
        // A Mac paired through its Obysphere is reached through it alone, at home too.
        let lan = URL(string: "http://192.168.1.20:8810")!
        var paired = envelope.link
        paired.relayed = mac.link.pinned
        #expect(RemoteRoute.choose(lan: lan, link: paired, paired: true) == .relay)
        #expect(RemoteRoute.choose(lan: lan, link: envelope.link, paired: true) == .home(lan))
        #expect(RemoteRoute.relay.url.scheme == "oby-relay")
    }

    @Test func theMacNotConnectedWaitsAndAReplacedSocketStays() async throws {
        let mac = FakeMac()
        let relay = mac.relay()
        let runner = Runner(base: RemoteRoute.relayBase, token: "t", relay: relay)
        // 4008: "Your Mac isn't reachable", and no new socket for 30 seconds...
        mac.closeOnHello = 4008
        await #expect(throws: RunnerError.self) { try await runner.send("GET", "v1/status") }
        do { _ = try await runner.send("GET", "v1/status") } catch let error as RunnerError {
            #expect(error.message == "Your Mac isn't reachable.")
        }
        #expect(mac.sockets.count == 1)
        #expect(await relay.backoff == 30)
        // ...doubling after each 4008, up to 5 minutes...
        for wait in [60.0, 120, 240, 300, 300] {
            await relay.resume()
            await #expect(throws: RunnerError.self) { try await runner.send("GET", "v1/status") }
            #expect(await relay.backoff == wait)
        }
        #expect(mac.sockets.count == 6)
        // ...and at once when the person asks; a welcome starts the doubling over.
        mac.closeOnHello = nil
        await relay.resume()
        _ = try await runner.send("GET", "v1/status")
        #expect(mac.sockets.count == 7)
        #expect(await relay.backoff == 0)
        // 4003: another socket of this phone's took over: never again by itself.
        mac.sockets.last?.close(4003)
        for _ in 0..<50 { try await Task.sleep(for: .milliseconds(10)) }
        await #expect(throws: RunnerError.self) { try await runner.send("GET", "v1/status") }
        #expect(mac.sockets.count == 7)
        await relay.resume()
        _ = try await runner.send("GET", "v1/status")
        #expect(mac.sockets.count == 8)
    }

    @Test func aForgottenPhoneIsRemoved() async throws {
        let mac = FakeMac()
        mac.refuse = 401
        let runner = Runner(base: RemoteRoute.relayBase, token: "t", relay: mac.relay())
        do {
            _ = try await runner.send("GET", "v1/status")
            Issue.record("a forgotten relay token went through")
        } catch let error as RunnerError {
            #expect(error.status == 401)
        }
        #expect(Phone.refusal(after: PhoneRelay.forgotten, was: nil) == 401)
    }

    @Test func aGapOrTheMacsResetStartsANewSession() async throws {
        let mac = FakeMac()
        let runner = Runner(base: RemoteRoute.relayBase, token: "t", relay: mac.relay())
        _ = try await runner.send("GET", "v1/status")
        // An envelope of the Mac's lost on the way: the answer after it opens past the next.
        mac.skip = true
        await #expect(throws: (any Error).self) { try await runner.send("GET", "v1/status") }
        // The next request says hello again, on the same socket.
        _ = try await runner.send("GET", "v1/status")
        #expect(mac.hellos == 2 && mac.sockets.count == 1)
        // obid's sealed reset on stream 0 ends the session too.
        mac.resetSession = true
        await #expect(throws: (any Error).self) { try await runner.send("GET", "v1/status") }
        _ = try await runner.send("GET", "v1/status")
        #expect(mac.hellos == 3 && mac.sockets.count == 1)
    }

    /// obid answers nothing to a hello it can't open, so a welcome that doesn't open is an earlier
    /// hello's, come late, or forged: ignored, while the hello waits for its own.
    @Test func aLateWelcomeIsIgnored() async throws {
        let mac = FakeMac()
        mac.lateWelcome = true
        let runner = Runner(base: RemoteRoute.relayBase, token: "t", relay: mac.relay())
        _ = try await runner.send("GET", "v1/status")
        #expect(mac.hellos == 1 && mac.sockets.count == 1)
    }

    /// Only a forged welcome (the Sphere with a key of its own): nothing starts, no false "key
    /// changed", each request tries again on a new socket, and "pair again" comes only after three
    /// hellos in a row went unanswered.
    @Test func aForgedWelcomeAloneIsNoAnswer() async throws {
        let mac = FakeMac()
        mac.impostor = true
        let runner = Runner(base: RemoteRoute.relayBase, token: "t", relay: mac.relay(patience: 0.2))
        var said: [String] = []
        for _ in 0..<4 {
            do {
                _ = try await runner.send("GET", "v1/status")
                Issue.record("a forged welcome started a session")
            } catch let error as RunnerError { said.append(error.message) }
        }
        #expect(said == [PhoneRelay.unanswered, PhoneRelay.unanswered, PhoneRelay.stillUnanswered, PhoneRelay.stillUnanswered].map(\.message))
        #expect(mac.sockets.count == 4)
        // A welcome starts the count over.
        mac.impostor = false
        _ = try await runner.send("GET", "v1/status")
        mac.impostor = true
        mac.sockets.last?.close(1006)
        try await Task.sleep(for: .milliseconds(100))
        do { _ = try await runner.send("GET", "v1/status") } catch let error as RunnerError {
            #expect(error.message == PhoneRelay.unanswered.message)
        }
    }

    /// An answer that starts and then goes quiet ends, and the Mac is told to stop it; the session goes on.
    @Test func aQuietAnswerTimesOut() async throws {
        let mac = FakeMac()
        mac.quietAfterHead = true
        let runner = Runner(base: RemoteRoute.relayBase, token: "t", relay: mac.relay())
        await #expect(throws: URLError.self) { try await runner.send("GET", "v1/status", timeout: 1) }
        try await mac.until { $0.contains { $0.kind == .reset && $0.stream == 1 } }
        mac.quietAfterHead = false
        _ = try await runner.send("GET", "v1/status")
        #expect(mac.hellos == 1)
    }

    /// An answer the reader doesn't keep up with is held only so far: then it ends and the Mac stops it.
    @Test func anAnswerFasterThanItsReaderIsBounded() async throws {
        let mac = FakeMac()
        mac.flood = PhoneRelay.held + 10
        let relay = mac.relay()
        let (response, body) = try await relay.send(URLRequest(url: RemoteRoute.relayBase.appending(path: "v1/artifacts/a/1/big")))
        #expect(response.statusCode == 200)
        try await mac.until { $0.contains { $0.kind == .reset && $0.stream == 1 } }
        // What was held is still read, then the answer ends with why.
        var chunks = 0
        await #expect(throws: RunnerError.self) { for try await _ in body { chunks += 1 } }
        #expect(chunks == PhoneRelay.held)
    }

    /// A pairing that fails closes its socket, and nothing of it is kept.
    @Test func aFailedPairingClosesItsSocket() async throws {
        let mac = FakeMac()
        mac.answer = { _, _ in (401, Data(#"{"error":"That pairing code is not valid."}"#.utf8)) }
        let phone = Phone()
        let before = phone.link
        await #expect(throws: RunnerError.self) {
            try await phone.pairRelay(mac.link, credential: "used", mac: MacLink(name: "Studio", hostname: "studio"), connect: mac.connect)
        }
        #expect(mac.sockets.count == 1 && mac.sockets[0].cancelled)
        #expect(phone.link == before)
        #expect(RelayStore.read() != mac.link)
    }

    /// A Mac paired through its Obysphere isn't restored as a tunnel pairing without its relay, and
    /// a device token only unreadable now (the iPhone locked) doesn't unpair.
    @Test func aRelayedPairingIsntRestoredWithoutItsRelay() throws {
        let savedLink = UserDefaults.standard.data(forKey: "mac.link")
        let hadToken = GatewayTokenStore.read()
        let hadRelay = RelayStore.read()
        defer {
            UserDefaults.standard.set(savedLink, forKey: "mac.link")
            if let hadToken { try? GatewayTokenStore.save(hadToken) } else { GatewayTokenStore.remove() }
            if let hadRelay { try? RelayStore.save(hadRelay) } else { RelayStore.remove() }
        }
        try GatewayTokenStore.save("tok-relay")
        RelayStore.remove()
        UserDefaults.standard.set(try MacLink(name: "Studio", hostname: "studio", relayed: "r.k").encoded(), forKey: "mac.link")
        #expect(Phone().link == nil)
        #expect(UserDefaults.standard.data(forKey: "mac.link") == nil)
        #expect(GatewayTokenStore.isMissing())
        // With its relay, it's back, reached through it.
        let mac = FakeMac()
        try GatewayTokenStore.save("tok-relay")
        try RelayStore.save(mac.link)
        UserDefaults.standard.set(try MacLink(name: "Studio", hostname: "studio", relayed: mac.link.pinned).encoded(), forKey: "mac.link")
        let phone = Phone()
        #expect(phone.link?.relayed == mac.link.pinned && phone.route == .relay)
        #expect(!RelayStore.isMissing())
    }

    /// A Mac paired through its Obysphere is that Mac by its relay and pinned key, not by the name
    /// an invitation carries: one pasted with the same hostname is another Mac, with nothing of the
    /// first's (its queued messages, its device id, what it pushes with).
    @Test func aRelayedMacIsKnownByItsRelayNotItsName() throws {
        let first = FakeMac(), other = FakeMac()
        let mine = MacLink(name: "Studio", hostname: "oby-abcdefghijklmnop.tetrix.pro", relayed: first.link.pinned)
        let theirs = MacLink(name: "Studio", hostname: "oby-abcdefghijklmnop.tetrix.pro", relayed: other.link.pinned)
        #expect(mine.identity != theirs.identity)
        #expect(mine.identity != MacLink(name: "Studio", hostname: mine.hostname).identity)
        #expect(MacLink(name: "Studio", hostname: mine.hostname).identity == mine.hostname)
        // What's kept for one isn't the other's.
        let savedLink = UserDefaults.standard.data(forKey: "mac.link")
        let hadToken = GatewayTokenStore.read()
        let hadRelay = RelayStore.read()
        defer {
            UserDefaults.standard.set(savedLink, forKey: "mac.link")
            UserDefaults.standard.removeObject(forKey: "device.\(mine.identity)")
            if let hadToken { try? GatewayTokenStore.save(hadToken) } else { GatewayTokenStore.remove() }
            if let hadRelay { try? RelayStore.save(hadRelay) } else { RelayStore.remove() }
        }
        try GatewayTokenStore.save("tok-relay")
        UserDefaults.standard.set("device-1", forKey: "device.\(mine.identity)")
        try RelayStore.save(first.link)
        UserDefaults.standard.set(try mine.encoded(), forKey: "mac.link")
        #expect(Phone().deviceID == "device-1")
        try RelayStore.save(other.link)
        UserDefaults.standard.set(try theirs.encoded(), forKey: "mac.link")
        #expect(Phone().deviceID == nil)
    }
}

func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

func unhex(_ text: String) -> Data {
    var data = Data()
    var at = text.startIndex
    while at < text.endIndex {
        let next = text.index(at, offsetBy: 2)
        data.append(UInt8(text[at..<next], radix: 16)!)
        at = next
    }
    return data
}

/// The Mac's side of a session, as obid's `relay::envelope` makes it: it opens a hello and welcomes it.
nonisolated struct TestMac {
    let agreement: Curve25519.KeyAgreement.PrivateKey
    var publicKey: Data { agreement.publicKey.rawRepresentation }

    func welcome(_ hello: Data, ephemeral: Curve25519.KeyAgreement.PrivateKey = .init()) throws -> (Data, RelayEnvelope.Session) {
        let bytes = [UInt8](hello)
        let phone = Data(bytes[2..<34])
        let es = try RelayEnvelope.agree(agreement, phone)
        let offered = try RelayEnvelope.open(RelayEnvelope.derive(salt: publicKey + phone, ikm: es, info: "oby relay v1 hello"), 0,
                                             Data(bytes[34...]), aad: Data(bytes[..<34]))
        guard offered.contains(1) else { throw RelayEnvelope.Refused.unreadable }
        let mine = ephemeral.publicKey.rawRepresentation
        let ee = try RelayEnvelope.agree(ephemeral, phone)
        let salt = Data(SHA256.hash(data: hello + mine))
        let derived = { RelayEnvelope.derive(salt: salt, ikm: es + ee, info: $0) }
        let head = Data([1, 2]) + mine
        return (head + RelayEnvelope.seal(derived("oby relay v1 welcome"), 0, Data([1]), aad: head),
                RelayEnvelope.Session(version: 1, sealing: derived("oby relay v1 mac>phone"), opening: derived("oby relay v1 phone>mac")))
    }
}

/// An Obysphere and the Mac behind it, in one: what the phone sends on its socket reaches the Mac,
/// which answers each request as obid's relay does (sealed `open`, `data`, `end` on its stream).
nonisolated final class FakeMac: @unchecked Sendable {
    static let relayID = String(repeating: "r", count: 43)
    static let token = String(repeating: "t", count: 43)
    struct Head: Decodable { var method: String; var path: String; var headers: [String: String] }

    private let lock = NSLock()
    private let mac = TestMac(agreement: .init())
    private var session: RelayEnvelope.Session?
    private var asked: [UInt32: Head] = [:]
    private var lastStream: UInt32 = 0
    private var bodySoFar: [UInt32: Data] = [:]
    private(set) var sockets: [FakeSocket] = []
    private(set) var heads: [Head] = []
    private(set) var bodies: [Data] = []
    private(set) var frames: [RelayFrame] = []
    private(set) var hellos = 0
    var answer: (Head, Data) -> (Int, Data) = { _, _ in (200, Data("{}".utf8)) }
    /// An event stream's first chunk, answered to `/v1/events` and never ended.
    var streaming: Data?
    var closeOnHello: Int?
    var refuse: Int?
    /// Seal one envelope for the phone and lose it, before the next answer.
    var skip = false
    /// Answer the next request with obid's sealed reset on stream 0.
    var resetSession = false
    /// Answer hellos with a welcome of another key's.
    var impostor = false
    /// Before each welcome, one for an earlier hello, come late.
    var lateWelcome = false
    /// Answer with a head and then nothing.
    var quietAfterHead = false
    /// Answer with this many 64 KiB chunks at once, and no end.
    var flood = 0

    var link: RelayLink {
        RelayLink(sphere: URL(string: "https://sphere.example")!, id: Self.relayID, token: Self.token,
                  key: mac.publicKey.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: ""))
    }

    func relay(patience: TimeInterval = 5) -> PhoneRelay { PhoneRelay(link, connect: connect, patience: patience) }

    /// Waits up to 2 seconds for what the Mac heard to satisfy `heard`.
    func until(_ heard: ([RelayFrame]) -> Bool) async throws {
        for _ in 0..<100 where !heard(lock.withLock { frames }) { try await Task.sleep(for: .milliseconds(20)) }
        #expect(heard(lock.withLock { frames }))
    }

    var connect: PhoneRelay.Connect {
        { request in
            let socket = FakeSocket(request: request, mac: self)
            self.lock.withLock { self.sockets.append(socket) }
            if let refuse = self.refuse {
                socket.response = HTTPURLResponse(url: request.url!, statusCode: refuse, httpVersion: nil, headerFields: nil)
                socket.close(1006)
            }
            return socket
        }
    }

    func heard(_ envelope: Data, on socket: FakeSocket) {
        let bytes = [UInt8](envelope)
        if bytes[1] == 1 {
            lock.withLock { hellos += 1 }
            if let code = closeOnHello { return socket.close(code) }
            if impostor {
                let other = TestMac(agreement: .init())
                return socket.deliver(.data(try! other.welcome(try! RelayEnvelope.Hello(to: other.publicKey).bytes).0))
            }
            if lateWelcome { socket.deliver(.data(try! mac.welcome(try! RelayEnvelope.Hello(to: mac.publicKey).bytes).0)) }
            let (welcome, session) = try! mac.welcome(envelope)
            lock.withLock { self.session = session; lastStream = 0 }
            return socket.deliver(.data(welcome))
        }
        guard case .frame(let plain)? = lock.withLock({ session?.open(envelope) }), let frame = RelayFrame(plain) else { return }
        lock.withLock { frames.append(frame) }
        switch frame.kind {
        case .open:
            // As obid: a stream's id is above every earlier one's in the session, or it's ignored.
            let head = try! JSONDecoder().decode(Head.self, from: frame.payload)
            lock.withLock {
                guard frame.stream > lastStream else { return }
                lastStream = frame.stream
                asked[frame.stream] = head
                heads.append(head)
            }
        case .data:
            lock.withLock { bodySoFar[frame.stream, default: Data()].append(frame.payload) }
        case .end:
            guard let (head, body) = lock.withLock({ asked[frame.stream].map { ($0, bodySoFar[frame.stream] ?? Data()) } }) else { return }
            lock.withLock { bodies.append(body) }
            reply(head, body, stream: frame.stream, on: socket)
        case .reset:
            break
        }
    }

    private func reply(_ head: Head, _ body: Data, stream: UInt32, on socket: FakeSocket) {
        func send(_ frame: RelayFrame) { socket.deliver(.data(lock.withLock { session!.seal(frame.encoded) })) }
        if resetSession {
            resetSession = false
            return send(RelayFrame(stream: 0, kind: .reset, payload: Data("The session is over: send a new hello.".utf8)))
        }
        if skip {
            skip = false
            _ = lock.withLock { session!.seal(Data()) }
        }
        if quietAfterHead {
            return send(RelayFrame(stream: stream, kind: .open, payload: Data(#"{"status":200,"headers":{}}"#.utf8)))
        }
        if flood > 0 {
            send(RelayFrame(stream: stream, kind: .open, payload: Data(#"{"status":200,"headers":{}}"#.utf8)))
            for _ in 0..<flood { send(RelayFrame(stream: stream, kind: .data, payload: Data(count: 65_536))) }
            return
        }
        if head.path == "/v1/events", let streaming {
            send(RelayFrame(stream: stream, kind: .open, payload: Data(#"{"status":200,"headers":{"content-type":"text/event-stream"}}"#.utf8)))
            return send(RelayFrame(stream: stream, kind: .data, payload: streaming))
        }
        let (status, answer) = answer(head, body)
        send(RelayFrame(stream: stream, kind: .open, payload: Data(#"{"status":\#(status),"headers":{"content-type":"application/json"}}"#.utf8)))
        send(RelayFrame(stream: stream, kind: .data, payload: answer))
        send(RelayFrame(stream: stream, kind: .end))
    }
}

/// The phone's socket at the fake Sphere.
nonisolated final class FakeSocket: RelaySocket, @unchecked Sendable {
    let request: URLRequest
    private weak var mac: FakeMac?
    private let lock = NSLock()
    private var queue: [URLSessionWebSocketTask.Message] = []
    private var waiter: CheckedContinuation<URLSessionWebSocketTask.Message, Error>?
    private var closed = false
    private(set) var sent: [URLSessionWebSocketTask.Message] = []
    private(set) var closeCode: URLSessionWebSocketTask.CloseCode = .invalid
    /// PhoneRelay closed it.
    private(set) var cancelled = false
    var response: URLResponse?

    init(request: URLRequest, mac: FakeMac) {
        self.request = request
        self.mac = mac
    }

    func deliver(_ message: URLSessionWebSocketTask.Message) {
        lock.withLock {
            if let waiter {
                self.waiter = nil
                waiter.resume(returning: message)
            } else {
                queue.append(message)
            }
        }
    }

    /// The Sphere closes it with `code`.
    func close(_ code: Int) {
        lock.withLock {
            closeCode = URLSessionWebSocketTask.CloseCode(rawValue: code) ?? .invalid
            closed = true
            waiter?.resume(throwing: URLError(.networkConnectionLost))
            waiter = nil
        }
    }

    func receive() async throws -> URLSessionWebSocketTask.Message {
        try await withCheckedThrowingContinuation { continuation in
            lock.withLock {
                if !queue.isEmpty {
                    continuation.resume(returning: queue.removeFirst())
                } else if closed {
                    continuation.resume(throwing: URLError(.networkConnectionLost))
                } else {
                    waiter = continuation
                }
            }
        }
    }

    func send(_ message: URLSessionWebSocketTask.Message) async throws {
        let isClosed = lock.withLock {
            sent.append(message)
            return closed
        }
        if isClosed { throw URLError(.networkConnectionLost) }
        if case .data(let data) = message { mac?.heard(data, on: self) }
    }

    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        lock.withLock {
            cancelled = true
            closed = true
            waiter?.resume(throwing: URLError(.cancelled))
            waiter = nil
        }
    }
}
