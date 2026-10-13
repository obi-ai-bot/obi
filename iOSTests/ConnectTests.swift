import Foundation
import Testing
@testable import Oby

/// The Connect screen's pairing (#284, iOS/ConnectScreen.swift and iOS/Phone.swift): what the
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
        let text = #"{"url":"http://192.168.1.20:8810","link":{"hostname":"oby-abc.tetrix.pro","name":"Wellington's MacBook Air"},"secret":"one-time"}"#
        let envelope = try GatewayEnvelope.decode(text)
        #expect(envelope.url == gateway)
        #expect(envelope.link == MacLink(name: "Wellington's MacBook Air", hostname: "oby-abc.tetrix.pro"))
        #expect(envelope.secret == "one-time")
        // Any other QR code says what to scan instead.
        #expect(throws: RunnerError.self) { try GatewayEnvelope.decode("https://example.com/menu") }
    }

    @Test func aTypedCodeIsSixDigits() {
        #expect(PairingCode.normalized("123456") == "123456")
        #expect(PairingCode.normalized(" 123 456 ") == "123456")
        #expect(PairingCode.normalized("123-456") == "123456")
        for wrong in ["12345", "1234567", "12345a", "", "abcdef", "123456 7"] {
            #expect(PairingCode.normalized(wrong) == nil, Comment(rawValue: wrong))
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
}
