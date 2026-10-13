import Crypto
import Foundation
import Testing
@testable import ObyShared
@testable import oby_runner

struct E2ETests {
    let mac = E2E.KeyPair()
    let phone = E2E.KeyPair()

    @Test func roundTripUsesHPKEAndAuthenticatesMetadata() throws {
        let metadata = E2E.Metadata(method: "POST", route: "/v1/plans", device: "phone", counter: 1)
        let clear = Data(#"{"said":"keep this private"}"#.utf8)
        let wire = try E2E.seal(clear, to: mac.publicKey, metadata: metadata)
        #expect(wire != clear)
        #expect(try E2E.open(wire, with: mac.privateKey, metadata: metadata) == clear)
    }

    @Test func tamperedBodyAndMetadataAreRejected() throws {
        let metadata = E2E.Metadata(method: "POST", route: "/v1/plans", device: "phone", counter: 1)
        let wire = try E2E.seal(Data("secret".utf8), to: mac.publicKey, metadata: metadata)
        var envelope = try E2E.Envelope.decoded(wire)
        envelope = E2E.Envelope(encapsulatedKey: envelope.encapsulatedKey,
                                ciphertext: Data(envelope.ciphertext.reversed()))
        #expect(throws: E2E.Failure.invalidMessage) { try E2E.open(try envelope.encoded(), with: mac.privateKey, metadata: metadata) }
        #expect(throws: E2E.Failure.invalidMessage) {
            try E2E.open(wire, with: mac.privateKey,
                         metadata: E2E.Metadata(method: "GET", route: metadata.route, device: metadata.device, counter: 1))
        }
    }

    @Test func replayGuardRejectsRepeatedAndOlderRequestsPerDevice() throws {
        let guardrail = E2E.ReplayGuard()
        try guardrail.accept(E2E.Metadata(method: "GET", route: "/v1/status", device: "phone", counter: 1))
        try guardrail.record(E2E.Metadata(method: "GET", route: "/v1/status", device: "phone", counter: 1))
        #expect(throws: E2E.Failure.replay) {
            try guardrail.accept(E2E.Metadata(method: "GET", route: "/v1/status", device: "phone", counter: 1))
        }
        #expect(throws: E2E.Failure.replay) {
            try guardrail.accept(E2E.Metadata(method: "GET", route: "/v1/status", device: "phone", counter: 0))
        }
        try guardrail.accept(E2E.Metadata(method: "GET", route: "/v1/status", device: "watch", counter: 1))
    }

    @Test func acceptAndRecordAllowsOnlyOneConcurrentCopy() async throws {
        let guardrail = E2E.ReplayGuard()
        let metadata = E2E.Metadata(method: "POST", route: "/v1/plans", device: "phone", counter: 1)
        let accepted = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
            for _ in 0..<16 {
                group.addTask { (try? guardrail.acceptAndRecord(metadata)) != nil }
            }
            var count = 0
            for await result in group { if result { count += 1 } }
            return count
        }
        #expect(accepted == 1)
    }

    @Test func gatewayDecryptsOnlyAfterReplayChecks() throws {
        let gateway = Gateway(keys: mac, devices: ["phone": phone.publicKey])
        let metadata = E2E.Metadata(method: "POST", route: "/v1/plans", device: "phone", counter: 1)
        let wire = try E2E.seal(Data("private".utf8), to: gateway.publicKey, metadata: metadata, authenticatedBy: phone.privateKey)
        #expect(try gateway.open(wire, metadata: metadata) == Data("private".utf8))
        #expect(throws: E2E.Failure.replay) { try gateway.open(wire, metadata: metadata) }
    }

    @Test func unauthenticatedCounterCannotLockOutADeviceAndReplaySurvivesRestart() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "oby-e2e-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let replay = folder.appending(path: "replay.json")
        let metadata = E2E.Metadata(method: "POST", route: "/v1/plans", device: "phone", counter: UInt64.max)
        let gateway = Gateway(keys: mac, replayFile: replay, devices: ["phone": phone.publicKey])
        let junk = try E2E.seal(Data("junk".utf8), to: gateway.publicKey, metadata: metadata)
        #expect(throws: E2E.Failure.invalidMessage) { try gateway.open(junk, metadata: metadata) }
        let valid = try E2E.seal(Data("valid".utf8), to: gateway.publicKey, metadata: metadata, authenticatedBy: phone.privateKey)
        #expect(try gateway.open(valid, metadata: metadata) == Data("valid".utf8))
        let restarted = Gateway(keys: mac, replayFile: replay, devices: ["phone": phone.publicKey])
        #expect(throws: E2E.Failure.replay) { try restarted.open(valid, metadata: metadata) }
    }

    @Test func clientSealsRequestsAndOpensAuthenticatedResponses() throws {
        let counterKey = "oby-test-e2e-\(UUID().uuidString)"
        let client = try E2E.Client(device: "phone", keys: phone, gatewayPublicKey: mac.publicKey, counterKey: counterKey)
        let request = try client.seal(Data("private request".utf8), method: "POST", route: "/v1/plans")
        let gateway = Gateway(keys: mac, devices: ["phone": phone.publicKey])
        #expect(try gateway.open(request.body, metadata: request.metadata) == Data("private request".utf8))
        let responseMetadata = E2E.Metadata(method: "POST", route: "/v1/plans", device: "phone",
                                            counter: request.metadata.counter, direction: .response)
        let response = try E2E.seal(Data("private response".utf8), to: phone.publicKey,
                                    metadata: responseMetadata, authenticatedBy: mac.privateKey)
        #expect(try client.open(response, metadata: responseMetadata) == Data("private response".utf8))
    }
}
