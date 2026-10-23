import CryptoKit
import Foundation
import Testing
@testable import Oby

/// A hook (#1128) is made at the control plane, signed by this Mac's key, then given to obid with
/// its secret; when obid refuses it, its address goes again.
struct HooksTests {
    /// The control plane's stand-in: what it answers, in order, and every request it got.
    final class Plane: @unchecked Sendable {
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
    }

    let key = P256.Signing.PrivateKey()
    var signer: ControlPlane.Signer {
        let key = key
        return ControlPlane.Signer(publicKey: key.publicKey.x963Representation, sign: { try key.signature(for: $0).rawRepresentation })
    }

    static let made = #"{"hook": {"id": "abcdefghij0123456789abcdefghij01", "url": "https://oby-control.test/h/abcdefghij0123456789abcdefghij01", "createdAt": "2026-10-23T03:12:00.000Z"}}"#

    @Test func aHookIsMadeAtTheControlPlaneThenInObid() async throws {
        let plane = Plane([(201, Self.made)])
        let obid = RunnerStub { request in
            (201, #"{"id": "abcdefghij0123456789abcdefghij01", "name": "prom", "source": "generic", "repo": "obi-ai-bot/obi", "url": "https://oby-control.test/h/abcdefghij0123456789abcdefghij01", "createdAt": "2026-10-23T03:12:00Z", "lastDelivery": null}"#)
        }
        let secret = HookSetup.newSecret()
        #expect(secret.count == 64 && secret != HookSetup.newSecret())
        let row = try await HookSetup.make(name: "prom", source: "generic", repo: "obi-ai-bot/obi", secret: secret,
                                           plane: ControlPlane(base: URL(string: "https://oby-control.test")!, transport: plane.transport),
                                           signer: signer, obid: obid.runner)
        #expect(row.name == "prom" && row.lastDelivery == nil)
        let first = try #require(plane.requests.first)
        #expect(first.httpMethod == "POST" && first.url?.path() == "/v1/installations/self/hooks")
        #expect(first.value(forHTTPHeaderField: "Oby-Signature") != nil && first.value(forHTTPHeaderField: "Oby-Key") != nil)
        #expect(!(first.httpBody.map { String(decoding: $0, as: UTF8.self) } ?? "").contains(secret), "the control plane never gets the secret")
        let given = try #require(obid.requests.last?.json)
        #expect(given["id"] as? String == "abcdefghij0123456789abcdefghij01" && given["secret"] as? String == secret)
        #expect(given["url"] as? String == "https://oby-control.test/h/abcdefghij0123456789abcdefghij01")
    }

    /// Removing a hook obid no longer has (an earlier try got that far) still removes its address.
    @Test func removingAHookObidForgotStillRemovesItsAddress() async throws {
        let plane = Plane([(204, "")])
        let obid = RunnerStub { _ in (404, #"{"error": "There's no such hook."}"#) }
        try await HookSetup.remove(id: "abcdefghij0123456789abcdefghij01",
                                   plane: ControlPlane(base: URL(string: "https://oby-control.test")!, transport: plane.transport),
                                   signer: signer, obid: obid.runner)
        #expect(plane.requests.map { "\($0.httpMethod ?? "") \($0.url?.path() ?? "")" } == ["DELETE /v1/installations/self/hooks/abcdefghij0123456789abcdefghij01"])
    }

    @Test func aHookObidRefusesIsRemovedFromTheControlPlane() async throws {
        let plane = Plane([(201, Self.made), (204, "")])
        let obid = RunnerStub { _ in (422, #"{"error": "name is up to 32 lower-case letters, digits or dashes."}"#) }
        await #expect(throws: (any Error).self) {
            try await HookSetup.make(name: "Bad Name", source: "generic", repo: nil, secret: HookSetup.newSecret(),
                                     plane: ControlPlane(base: URL(string: "https://oby-control.test")!, transport: plane.transport),
                                     signer: signer, obid: obid.runner)
        }
        #expect(plane.requests.map { "\($0.httpMethod ?? "") \($0.url?.path() ?? "")" }
                == ["POST /v1/installations/self/hooks", "DELETE /v1/installations/self/hooks/abcdefghij0123456789abcdefghij01"])
    }
}
