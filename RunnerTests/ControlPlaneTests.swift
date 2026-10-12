import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import ObyEngine

/// The control plane's API (cloud/control-plane, #285), as the Mac calls it: each call's method,
/// path, bearer and body, and what comes back, against a stand-in transport.
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

        func plane() -> ControlPlane { ControlPlane(base: URL(string: "https://oby-control.test")!, transport: transport) }
    }

    @Test func signsInWithAnEmailedCode() async throws {
        let exchange = Exchange([
            (202, #"{"sent": true}"#),
            (201, #"{"token": "oby_session_abc", "user": {"id": "u1", "email": "well@example.com"}, "expiresAt": "2027-01-10T12:00:00.000Z"}"#),
            (200, #"{"user": {"id": "u1", "email": "well@example.com"}}"#),
        ])
        let plane = exchange.plane()
        try await plane.requestCode(email: "well@example.com")
        let session = try await plane.verify(email: "well@example.com", code: "123456")
        #expect(session.token == "oby_session_abc")
        #expect(session.user == ControlPlane.User(id: "u1", email: "well@example.com"))
        #expect(session.expiresAt == ControlPlane.date(from: "2027-01-10T12:00:00Z"))
        #expect(try await plane.me(session: session.token).email == "well@example.com")

        let requests = exchange.requests
        #expect(requests.map { $0.httpMethod ?? "" } == ["POST", "POST", "GET"])
        #expect(requests.map { $0.url?.path ?? "" } == ["/v1/auth/otp/request", "/v1/auth/otp/verify", "/v1/me"])
        #expect(try JSONDecoder().decode([String: String].self, from: requests[0].httpBody ?? Data()) == ["email": "well@example.com"])
        #expect(try JSONDecoder().decode([String: String].self, from: requests[1].httpBody ?? Data()) == ["email": "well@example.com", "code": "123456"])
        #expect(requests[0].value(forHTTPHeaderField: "Authorization") == nil)
        #expect(requests[2].value(forHTTPHeaderField: "Authorization") == "Bearer oby_session_abc")
        #expect(requests[0].value(forHTTPHeaderField: "Content-Type") == "application/json")
    }

    @Test func registersTheMacAndGetsItsTunnel() async throws {
        let installation = #"{"id": "i1", "clientId": "mac-client-0001", "name": "MacBook", "platform": "macos", "createdAt": "2026-10-12T12:00:00.000Z", "lastSeenAt": null, "endpoint": null}"#
        let endpoint = #"{"hostname": "oby-abcdefghij0123456789.tetrix.pro", "tunnelId": "t1", "createdAt": "2026-10-12T12:00:01.000Z"}"#
        let exchange = Exchange([
            (201, #"{"installation": \#(installation), "credential": "oby_install_xyz"}"#),
            (201, #"{"endpoint": \#(endpoint)}"#),
            (200, #"{"token": "eyJ-run-token", "hostname": "oby-abcdefghij0123456789.tetrix.pro"}"#),
            (200, #"{"installation": {"id": "i1", "clientId": "mac-client-0001", "name": "MacBook", "platform": "macos", "createdAt": "2026-10-12T12:00:00.000Z", "lastSeenAt": "2026-10-12T12:00:02Z", "endpoint": \#(endpoint)}}"#),
            (204, ""),
            (204, ""),
        ])
        let plane = exchange.plane()
        let registered = try await plane.register(session: "oby_session_abc", clientID: "mac-client-0001", name: "MacBook")
        #expect(registered.credential == "oby_install_xyz")
        #expect(registered.installation.id == "i1")
        #expect(registered.installation.endpoint == nil)
        let made = try await plane.createEndpoint(credential: registered.credential)
        #expect(made.hostname == "oby-abcdefghij0123456789.tetrix.pro")
        let token = try await plane.tunnelToken(credential: registered.credential)
        #expect(token == ControlPlane.TunnelToken(token: "eyJ-run-token", hostname: made.hostname))
        let mine = try await plane.installation(credential: registered.credential)
        #expect(mine.endpoint?.tunnelId == "t1")
        #expect(mine.lastSeenAt == ControlPlane.date(from: "2026-10-12T12:00:02Z"))
        try await plane.removeEndpoint(credential: registered.credential)
        try await plane.remove("i1", session: "oby_session_abc")

        let requests = exchange.requests
        #expect(requests.map { "\($0.httpMethod ?? "") \($0.url?.path ?? "")" } == [
            "POST /v1/installations", "POST /v1/installations/self/endpoint", "GET /v1/installations/self/endpoint/token",
            "GET /v1/installations/self", "DELETE /v1/installations/self/endpoint", "DELETE /v1/installations/i1",
        ])
        #expect(try JSONDecoder().decode([String: String].self, from: requests[0].httpBody ?? Data())
                == ["clientId": "mac-client-0001", "name": "MacBook", "platform": "macos"])
        #expect(requests[0].value(forHTTPHeaderField: "Authorization") == "Bearer oby_session_abc")
        #expect(requests[1].value(forHTTPHeaderField: "Authorization") == "Bearer oby_install_xyz")
        #expect(requests[5].value(forHTTPHeaderField: "Authorization") == "Bearer oby_session_abc")
    }

    @Test func saysWhatTheControlPlaneSaid() async throws {
        let exchange = Exchange([
            (401, #"{"error": "Sign in again."}"#),
            (502, "<html>bad gateway</html>"),
            (0, ""),
            (200, "not json"),
        ])
        let plane = exchange.plane()
        await #expect(throws: ControlPlane.Failure(message: "Sign in again.", status: 401)) { try await plane.me(session: "oby_session_old") }
        await #expect(throws: ControlPlane.Failure(message: "The control plane answered 502.", status: 502)) { try await plane.me(session: "x") }
        await #expect(throws: ControlPlane.Failure(message: "The control plane didn't answer.", status: 0)) { try await plane.me(session: "x") }
        await #expect(throws: ControlPlane.Failure(message: "The control plane's answer couldn't be read.", status: 0)) { try await plane.me(session: "x") }
    }

    @Test func readsDatesWithOrWithoutFractions() {
        #expect(ControlPlane.date(from: "2026-10-12T12:00:00.250Z") == Date(timeIntervalSince1970: 1_791_806_400.25))
        #expect(ControlPlane.date(from: "2026-10-12T12:00:00Z") == Date(timeIntervalSince1970: 1_791_806_400))
        #expect(ControlPlane.date(from: "yesterday") == nil)
    }
}
