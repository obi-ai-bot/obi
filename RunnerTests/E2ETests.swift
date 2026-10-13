import Crypto
import Foundation
import Testing
@testable import ObyShared
@testable import oby_runner

struct E2ETests {
    let mac = E2E.KeyPair()

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
        #expect(throws: E2E.Failure.replay) {
            try guardrail.accept(E2E.Metadata(method: "GET", route: "/v1/status", device: "phone", counter: 1))
        }
        #expect(throws: E2E.Failure.replay) {
            try guardrail.accept(E2E.Metadata(method: "GET", route: "/v1/status", device: "phone", counter: 0))
        }
        try guardrail.accept(E2E.Metadata(method: "GET", route: "/v1/status", device: "watch", counter: 1))
    }

    @Test func gatewayDecryptsOnlyAfterReplayChecks() throws {
        let gateway = Gateway(keys: mac)
        let metadata = E2E.Metadata(method: "POST", route: "/v1/plans", device: "phone", counter: 1)
        let wire = try E2E.seal(Data("private".utf8), to: gateway.publicKey, metadata: metadata)
        #expect(try gateway.open(wire, metadata: metadata) == Data("private".utf8))
    }
}
