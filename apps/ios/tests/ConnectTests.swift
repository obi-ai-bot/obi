import Foundation
import Security
import Testing
@testable import Oby

/// The Connect screen's pairing (#284, apps/ios/app/ConnectScreen.swift and apps/ios/app/Phone.swift): what the
/// Mac's QR code carries, how a typed code is read, and that redeeming an invitation keeps the
/// device token in the keychain with the Mac's link, and keeps nothing when the Mac refuses.
@MainActor
struct ConnectTests {
    let gateway = URL(string: "http://192.168.1.20:8810")!

    /// What a fake gateway was sent.
    final class Sent {
        var request: URLRequest?
    }

    func answering(_ status: Int, _ body: String, sent: Sent) -> GatewayPairing.Transport {
        { request in
            sent.request = request
            return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
    }

    @Test func theQRCodeCarriesTheGatewayAndTheLink() throws {
        let text = #"{"url":"http://192.168.1.20:8810","link":{"hostname":"oby-abcdefghijklmnop.tetrix.pro","name":"Wellington's MacBook Air"},"secret":"one-time"}"#
        let envelope = try GatewayEnvelope.decode(text)
        #expect(envelope.url == gateway)
        #expect(envelope.link == MacLink(name: "Wellington's MacBook Air", hostname: "oby-abcdefghijklmnop.tetrix.pro"))
        #expect(envelope.secret == "one-time")
        // Any other QR code says what to scan instead.
        #expect(throws: RunnerError.self) { try GatewayEnvelope.decode("https://example.com/menu") }
    }

    /// obid's gateway behind `tailscale serve` (docs/runner-api.md, "obid only: the gateway"): the
    /// Mac's Tailscale name with its port is a link, kept across launches, reached over HTTPS.
    @Test func aTailscaleNameIsALink() throws {
        let text = #"{"url":"https://mac.tail0000.ts.net:8443","link":{"hostname":"mac.tail0000.ts.net:8443","name":"My Mac"},"secret":"one-time"}"#
        let envelope = try GatewayEnvelope.decode(text)
        let kept = try MacLink.paired(try envelope.link.encoded())
        #expect(kept.tunnelURL.absoluteString == "https://mac.tail0000.ts.net:8443")
        #expect(MacLink.hostname(from: "https://Mac.tail0000.ts.net:8443/") == "mac.tail0000.ts.net:8443")
        for wrong in ["ts.net", "mac.ts.net", "mac.tail0000.ts.net.evil.com", "mac.tail0000.ts.net:", "evil.com:8443"] {
            #expect(!MacLink.isHostname(wrong), Comment(rawValue: wrong))
        }
    }

    /// A pasted invitation can't send this iPhone somewhere other than the Mac it names: the URL is
    /// the link's own hostname over HTTPS, or a home-network gateway over HTTP.
    @Test func anInvitationPointsAtTheMacItNames() {
        let link = #"{"hostname":"mac.tail0000.ts.net:8443","name":"My Mac"}"#
        for url in ["https://evil.example", "https://mac.tail0000.ts.net", "http://mac.tail0000.ts.net:8443", "http://8.8.8.8:8810", "ftp://192.168.1.20"] {
            #expect(throws: RunnerError.self, Comment(rawValue: url)) {
                try GatewayEnvelope.decode(#"{"url":"\#(url)","link":\#(link),"secret":"s"}"#)
            }
        }
        #expect(throws: RunnerError.self) {
            try GatewayEnvelope.decode(#"{"url":"https://evil.example","link":{"hostname":"evil.example","name":"M"},"secret":"s"}"#)
        }
        for url in ["https://mac.tail0000.ts.net:8443", "http://192.168.1.20:8810", "http://10.0.0.5:8810", "http://my-mac.local:8810"] {
            #expect((try? GatewayEnvelope.decode(#"{"url":"\#(url)","link":\#(link),"secret":"s"}"#)) != nil, Comment(rawValue: url))
        }
    }

    /// The background wait for a job's end carries the device token, as every gateway call does:
    /// without it the gateway answers 401 and the Lock Screen never hears the job ended.
    @Test func theBackgroundWaitCarriesTheDeviceToken() {
        let url = URL(string: "https://mac.tail0000.ts.net:8443/v1/jobs/j1/wait")!
        #expect(JobWaiter.request(url, token: "tok-1").value(forHTTPHeaderField: "Authorization") == "Bearer tok-1")
        #expect(JobWaiter.request(url, token: nil).value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func aTypedCodeIsSixDigits() {
        #expect(PairingCode.normalized("123456") == "123456")
        #expect(PairingCode.normalized(" 123 456 ") == "123456")
        #expect(PairingCode.normalized("123-456") == "123456")
        for wrong in ["12345", "1234567", "12345a", "", "abcdef", "123456 7"] {
            #expect(PairingCode.normalized(wrong) == nil, Comment(rawValue: wrong))
        }
    }

    @Test func aMacLinkNeedsItsDeviceTokenBeforeRequestsCanUseItsGateway() {
        let link = MacLink(name: "My Mac", hostname: "oby-abc.tetrix.pro")
        let lan = URL(string: "http://192.168.1.20:8810")!
        #expect(RemoteRoute.choose(lan: lan, link: link, paired: false) == nil)
        #expect(RemoteRoute.choose(lan: nil, link: link, paired: false) == nil)
        #expect(RemoteRoute.choose(lan: lan, link: link, paired: true) == .home(lan))
        #expect(RemoteRoute.choose(lan: nil, link: link, paired: true) == .away(link.tunnelURL))
    }

    @Test func aFailedKeychainAddFailsPairing() {
        #expect(throws: RunnerError.self) {
            try GatewayTokenStore.validateSave(updateStatus: errSecItemNotFound) { errSecAuthFailed }
        }
    }

    @Test func redeemingKeepsTheTokenInTheKeychainWithTheLink() async throws {
        defer { GatewayTokenStore.remove() }
        let sent = Sent()
        let body = #"{"token":"tok-1","deviceID":"d1","expiresAt":"2026-11-12T10:00:00Z","link":{"name":"My Mac","hostname":"oby-abc.tetrix.pro"}}"#
        let answer = try await GatewayPairing.redeem(at: gateway, credential: "123456", name: "Test iPhone", transport: answering(200, body, sent: sent))
        // The credential goes to the gateway's pairing endpoint, with this iPhone's name.
        #expect(sent.request?.url?.absoluteString == "http://192.168.1.20:8810/v1/pairing")
        #expect(sent.request?.httpMethod == "POST")
        let posted = try #require(sent.request?.httpBody)
        let fields = try JSONDecoder().decode([String: String].self, from: posted)
        #expect(fields == ["credential": "123456", "name": "Test iPhone"])
        // The token is in the keychain, and the answer says which Mac was paired.
        #expect(answer.token == "tok-1")
        #expect(answer.link == MacLink(name: "My Mac", hostname: "oby-abc.tetrix.pro"))
        #expect(GatewayTokenStore.read() == "tok-1")
        // How long the pairing lasts, for "Paired until Nov 12" and a clear word when it ends.
        #expect(answer.expiresAt == ISO8601DateFormatter().date(from: "2026-11-12T10:00:00Z"))
        // An older runner's answer, without the link, still pairs.
        let bare = try await GatewayPairing.redeem(at: gateway, credential: "123456", name: "Test iPhone",
                                                   transport: answering(200, #"{"token":"tok-2","expiresAt":"2026-11-12T10:00:00Z"}"#, sent: sent))
        #expect(bare.link == nil)
        #expect(GatewayTokenStore.read() == "tok-2")
    }

    @Test func aRefusalSaysWhyAndKeepsNoToken() async throws {
        GatewayTokenStore.remove()
        let sent = Sent()
        let refused = answering(401, #"{"error":"That pairing code is not valid."}"#, sent: sent)
        await #expect(throws: RunnerError.self) {
            try await GatewayPairing.redeem(at: gateway, credential: "000000", name: "Test iPhone", transport: refused)
        }
        do {
            _ = try await GatewayPairing.redeem(at: gateway, credential: "000000", name: "Test iPhone", transport: refused)
        } catch let error as RunnerError {
            #expect(error.message == "That pairing code is not valid.")
            #expect(error.status == 401)
        }
        #expect(GatewayTokenStore.read() == nil)
    }

    // MARK: Pairing that just works (docs/oby-ux.md rows 31-34, onboarding.md)

    @Test func aFreshIPhoneTalksToNobodyUntilItPairs() {
        // No default address: with no Mac and no runner, Connect is the first screen.
        #expect(Phone.needsPairing(linked: false, runner: nil, notice: nil))
        #expect(!Phone.needsPairing(linked: true, runner: nil, notice: nil))
        #expect(!Phone.needsPairing(linked: false, runner: URL(string: "https://runner.example"), notice: nil))
        // Removed from the Mac, or the 30 days are up: Connect again, with the line saying why.
        #expect(Phone.needsPairing(linked: true, runner: nil, notice: .removed))
        #expect(Phone.needsPairing(linked: true, runner: nil, notice: .expired))
        // Out of reach is Home with its notice, never the unpaired screen.
        #expect(!Phone.needsPairing(linked: true, runner: nil, notice: .unreachable(lastSeen: nil)))
    }

    @Test func theUnpairedScreenSaysWhyAndWhereOnTheMac() {
        // Its one line (apps/ios/app/Unpaired.swift): where to pair on the Mac, and why when the Mac stopped taking it.
        let pair = "Settings › Runner › Pair a device"
        #expect(UnpairedLine.message(nil) == "Let's connect to your Mac. On it, open \(pair).")
        #expect(UnpairedLine.message(.removed) == "Your Mac removed this iPhone. Pair again from \(pair).")
        #expect(UnpairedLine.message(.expired) == "Pairing ended after 30 days. Pair again from \(pair).")
    }

    @Test func theThirtyDaysEndingSaysSoInsteadOfBlamingTailscale() {
        let seen = Date(timeIntervalSince1970: 1_791_582_173)
        let ended = seen.addingTimeInterval(-60)
        #expect(ReachNotice.of(.offline("x"), online: true, status: 401, paired: true, lastSeen: seen, expires: ended, now: seen) == .expired)
        #expect(ReachNotice.of(.offline("x"), online: true, status: 401, paired: true, lastSeen: seen, expires: seen.addingTimeInterval(86_400), now: seen) == .removed)
        #expect(ReachNotice.expired.title == "Pairing with your Mac ended")
        #expect(ReachNotice.expired.detail == "It lasts 30 days. Scan the code in Oby on your Mac to connect again.")
    }

    /// Review of #683: a paired iPhone's 401 says its pairing ended, never the Tailscale line,
    /// and it holds through a dropped connection until a request succeeds.
    @Test func aRefusalSaysThePairingEndedAndHolds() throws {
        let refused = HTTPURLResponse(url: gateway, statusCode: 401, httpVersion: nil, headerFields: nil)!
        let said = "\(ReachNotice.expired.title). \(ReachNotice.expired.detail)"
        do { try Runner.check(refused, nil, refused: said); Issue.record("a 401 went through") } catch let error as RunnerError {
            #expect(error.message == said && error.status == 401)
        }
        do { try Runner.check(refused, nil) } catch let error as RunnerError {
            #expect(error.status == 401 && !error.message.contains("Tailscale"))
        }
        #expect(Phone.refusal(after: URLError(.networkConnectionLost), was: 401) == 401)
        #expect(Phone.refusal(after: RunnerError(message: "x", status: 500), was: 401) == 500)
        #expect(Phone.refusal(after: URLError(.timedOut), was: nil) == nil)
    }
}
