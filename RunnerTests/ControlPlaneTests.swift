import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import ObyEngine

/// The control plane's API (cloud/control-plane, #285), as the Mac calls it: each call's method,
/// path, body and signature, and what comes back, against a stand-in transport.
struct ControlPlaneTests {
    /// Records every request and answers from a script, in order.
    final class Exchange: @unchecked Sendable {
        var requests: [URLRequest] = []
        var answers: [(Int, String)]
        let lock = NSLock()
        init(_ answers: [(Int, String)]) { self.answers = answers }

        func transport(_ request: URLRequest) async throws -> (Data, Int) {
            lock.withLock {
                requests.append(request)
                guard !answers.isEmpty else { return (Data(), 500) }
                let (status, body) = answers.removeFirst()
                return (Data(body.utf8), status)
            }
        }

        func plane() -> ControlPlane {
            var plane = ControlPlane(base: URL(string: "https://oby-control.test")!, transport: transport)
            plane.now = { Date(timeIntervalSince1970: 1_791_806_400) }
            return plane
        }
    }

    /// A stand-in key: its public half is 65 bytes, and it "signs" by keeping what it was given.
    final class Signed: @unchecked Sendable {
        var messages: [Data] = []
        let lock = NSLock()
        var signer: ControlPlane.Signer {
            ControlPlane.Signer(publicKey: Data([4] + [UInt8](repeating: 0xAB, count: 64))) { message in
                self.lock.withLock { self.messages.append(message) }
                return Data(repeating: 0xCD, count: 64)
            }
        }
    }

    @Test func registersTheMacAndGetsItsTunnelSigningEveryCall() async throws {
        let installation = #"{"id": "i1", "name": "MacBook", "platform": "macos", "createdAt": "2026-10-12T12:00:00.000Z", "lastSeenAt": null, "endpoint": null}"#
        let endpoint = #"{"hostname": "oby-abcdefghij0123456789.tetrix.pro", "tunnelId": "t1", "createdAt": "2026-10-12T12:00:01.000Z"}"#
        let exchange = Exchange([
            (201, #"{"installation": \#(installation), "evicted": {"name": "Old Mac"}}"#),
            (201, #"{"endpoint": \#(endpoint)}"#),
            (200, #"{"token": "eyJ-run-token", "hostname": "oby-abcdefghij0123456789.tetrix.pro"}"#),
            (200, #"{"installation": {"id": "i1", "name": "MacBook", "platform": "macos", "createdAt": "2026-10-12T12:00:00.000Z", "lastSeenAt": "2026-10-12T12:00:02Z", "endpoint": \#(endpoint)}}"#),
            (204, ""),
            (204, ""),
        ])
        let plane = exchange.plane()
        let key = Signed()
        let registration = try await plane.register(key.signer, name: "MacBook", signIn: (state: "state-1", code: "code-1"))
        #expect(registration.evicted == ControlPlane.Registration.Evicted(name: "Old Mac"))
        let registered = registration.installation
        #expect(registered.id == "i1")
        #expect(registered.endpoint == nil)
        let made = try await plane.createEndpoint(key.signer)
        #expect(made.hostname == "oby-abcdefghij0123456789.tetrix.pro")
        let token = try await plane.tunnelToken(key.signer)
        #expect(token == ControlPlane.TunnelToken(token: "eyJ-run-token", hostname: made.hostname))
        let mine = try await plane.installation(key.signer)
        #expect(mine.endpoint?.tunnelId == "t1")
        #expect(mine.lastSeenAt == ControlPlane.date(from: "2026-10-12T12:00:02Z"))
        try await plane.removeEndpoint(key.signer)
        try await plane.forget(key.signer)

        let requests = exchange.requests
        #expect(requests.map { "\($0.httpMethod ?? "") \($0.url?.path ?? "")" } == [
            "POST /v1/installations", "POST /v1/installations/self/endpoint", "GET /v1/installations/self/endpoint/token",
            "GET /v1/installations/self", "DELETE /v1/installations/self/endpoint", "DELETE /v1/installations/self",
        ])
        let body = try #require(requests[0].httpBody)
        #expect(try JSONDecoder().decode([String: String].self, from: body) == ["name": "MacBook", "platform": "macos", "signIn": "state-1", "signInCode": "code-1"])
        // Every call is signed, never a bearer; each nonce is new.
        for request in requests {
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            #expect(request.value(forHTTPHeaderField: "Oby-Key") == "BKurq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6s")
            #expect(request.value(forHTTPHeaderField: "Oby-Timestamp") == "1791806400")
            #expect(request.value(forHTTPHeaderField: "Oby-Signature") == String(repeating: "zc3N", count: 21) + "zQ")
        }
        #expect(Set(requests.compactMap { $0.value(forHTTPHeaderField: "Oby-Nonce") }).count == requests.count)
        // What's signed: the version, the method, the path, the time and the nonce a line each, then the body.
        let nonce = try #require(requests[0].value(forHTTPHeaderField: "Oby-Nonce"))
        #expect(key.messages[0] == Data("oby-control-v1\nPOST\n/v1/installations\n1791806400\n\(nonce)\n".utf8) + body)
        let last = try #require(requests[5].value(forHTTPHeaderField: "Oby-Nonce"))
        #expect(key.messages[5] == Data("oby-control-v1\nDELETE\n/v1/installations/self\n1791806400\n\(last)\n".utf8))
    }

    @Test(arguments: ControlPlane.Provider.allCases)
    func startsASignIn(with provider: ControlPlane.Provider) async throws {
        let exchange = Exchange([(201, #"{"url": "https://example.com/authorize?state=s1", "state": "s1"}"#)])
        let key = Signed()
        let started = try await exchange.plane().startSignIn(key.signer, with: provider)
        #expect(started == ControlPlane.SignIn(url: URL(string: "https://example.com/authorize?state=s1")!, state: "s1"))
        #expect(exchange.requests.map { "\($0.httpMethod ?? "") \($0.url?.path ?? "")" } == ["POST /v1/auth/\(provider.rawValue)/start"])
        #expect(exchange.requests.first?.value(forHTTPHeaderField: "Oby-Signature") != nil)
    }

    @Test func saysWhatTheControlPlaneSaid() async throws {
        let exchange = Exchange([
            (403, #"{"error": "Sign in with Apple first."}"#),
            (410, #"{"error": "This Mac isn't registered. Turn remote access on again."}"#),
            (502, "<html>bad gateway</html>"),
            (0, ""),
            (200, "not json"),
        ])
        let plane = exchange.plane()
        let key = Signed().signer
        await #expect(throws: ControlPlane.Failure(message: "Sign in with Apple first.", status: 403)) {
            try await plane.register(key, name: "Mac")
        }
        await #expect(throws: ControlPlane.Failure(message: "This Mac isn't registered. Turn remote access on again.", status: 410)) { try await plane.installation(key) }
        await #expect(throws: ControlPlane.Failure(message: "The control plane answered 502.", status: 502)) { try await plane.installation(key) }
        await #expect(throws: ControlPlane.Failure(message: "The control plane didn't answer.", status: 0)) { try await plane.installation(key) }
        await #expect(throws: ControlPlane.Failure(message: "The control plane's answer couldn't be read.", status: 0)) { try await plane.installation(key) }
    }

    @Test func readsDatesWithOrWithoutFractions() {
        #expect(ControlPlane.date(from: "2026-10-12T12:00:00.250Z") == Date(timeIntervalSince1970: 1_791_806_400.25))
        #expect(ControlPlane.date(from: "2026-10-12T12:00:00Z") == Date(timeIntervalSince1970: 1_791_806_400))
        #expect(ControlPlane.date(from: "yesterday") == nil)
    }
}
