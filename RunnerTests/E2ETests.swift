import Crypto
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import Testing
@testable import ObyEngine
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

    @Test func replayGuardAllowsAuthenticatedRequestsThatFinishOutOfOrder() throws {
        let guardrail = E2E.ReplayGuard()
        let later = E2E.Metadata(method: "GET", route: "/v1/status", device: "phone", counter: 2)
        let earlier = E2E.Metadata(method: "GET", route: "/v1/status", device: "phone", counter: 1)
        try guardrail.acceptAndRecord(later)
        try guardrail.acceptAndRecord(earlier)
        #expect(throws: E2E.Failure.replay) { try guardrail.accept(earlier) }
    }

    @Test func replayGuardRejectsCountersOutsideItsWindow() throws {
        let guardrail = E2E.ReplayGuard()
        try guardrail.acceptAndRecord(E2E.Metadata(method: "GET", route: "/v1/status", device: "phone", counter: 100))
        #expect(throws: E2E.Failure.replay) {
            try guardrail.accept(E2E.Metadata(method: "GET", route: "/v1/status", device: "phone", counter: 36))
        }
        try guardrail.accept(E2E.Metadata(method: "GET", route: "/v1/status", device: "phone", counter: 37))
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

    @Test func aResponseCannotBeReplayedForANewerRequest() throws {
        let client = try E2E.Client(device: "phone", keys: phone, gatewayPublicKey: mac.publicKey,
                                    counterKey: "oby-test-response-replay-\(UUID().uuidString)")
        let first = try client.seal(Data("first".utf8), method: "GET", route: "/v1/jobs")
        let oldMetadata = E2E.Metadata(method: "GET", route: "/v1/jobs", device: "phone",
                                       counter: first.metadata.counter, direction: .response)
        let oldResponse = try E2E.seal(Data("old response".utf8), to: phone.publicKey,
                                       metadata: oldMetadata, authenticatedBy: mac.privateKey)
        let second = try client.seal(Data("second".utf8), method: "GET", route: "/v1/jobs")
        let newerMetadata = E2E.Metadata(method: "GET", route: "/v1/jobs", device: "phone",
                                         counter: second.metadata.counter, direction: .response)
        #expect(throws: E2E.Failure.invalidMessage) {
            try client.open(oldResponse, metadata: newerMetadata)
        }
    }

    @Test func sealedGetUsesTheEnvelopeHeaderAndNoBody() throws {
        var request = URLRequest(url: URL(string: "http://example/v1/jobs")!)
        request.httpMethod = "GET"
        let sealed = try E2E.Client(device: "phone", keys: phone, gatewayPublicKey: mac.publicKey,
                                    counterKey: "oby-test-get-header-\(UUID().uuidString)")
            .seal(Data(), method: "GET", route: "/v1/jobs")
        E2E.apply(sealed, to: &request)
        #expect(request.httpBody == nil)
        #expect(request.value(forHTTPHeaderField: E2E.envelopeHeader) == sealed.body.base64EncodedString())
        #expect(request.value(forHTTPHeaderField: "Oby-E2E-Version") == E2E.version)
    }

    /// Real URLSession GET (no stub): sealed empty body travels in the header and the gateway opens it.
    @MainActor
    @Test func sealedGetAndEventStreamLeaveThroughURLSession() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let devices = Devices(file: folder.appending(path: "devices.json"))
        _ = try devices.openPairing()
        let signing = P256.Signing.PrivateKey()
        let e2e = phone.publicKey.base64EncodedString()
        let publicKey = signing.publicKey.x963Representation.base64EncodedString()
        let proof = try signing.signature(for: Data("oby-e2e-register\n\(publicKey)\n\(e2e)".utf8))
            .derRepresentation.base64EncodedString()
        let id = try devices.register(name: "Phone", publicKey: publicKey, e2ePublicKey: e2e, e2eProof: proof)
        let gateway = Gateway(keys: mac, devices: devices.e2eKeys())
        let desk = Desk(accounts: AccountStore(root: folder), store: JobStore(url: folder.appending(path: "oby.sqlite")))
        let api = API(desk: desk, devices: devices)
        api.gateway = gateway
        let app = Application(router: api.router(access: .gateway, e2eAllowed: true, gateway: gateway))
        let client = try E2E.Client(device: id, keys: phone, gatewayPublicKey: mac.publicKey,
                                    counterKey: "oby-test-live-get-\(UUID().uuidString)")

        try await app.test(.live) { server in
            let port = try #require(server.port)
            let base = URL(string: "http://localhost:\(port)")!

            // GET /v1/jobs — must not set httpBody (URLSession -1103 on Apple).
            var jobsRequest = URLRequest(url: base.appending(path: "v1/jobs"))
            jobsRequest.httpMethod = "GET"
            let jobsSealed = try client.seal(Data(), method: "GET", route: "/v1/jobs")
            E2E.apply(jobsSealed, to: &jobsRequest)
            #expect(jobsRequest.httpBody == nil)
            #expect(jobsRequest.value(forHTTPHeaderField: E2E.envelopeHeader) != nil)
            let (jobsData, jobsResponse) = try await URLSession.shared.data(for: jobsRequest)
            let jobsStatus = (jobsResponse as? HTTPURLResponse)?.statusCode
            #expect(jobsStatus == 200)
            let jobsClear = try client.open(try E2E.unframe(jobsData),
                                            metadata: E2E.Metadata(method: "GET", route: "/v1/jobs", device: id,
                                                                   counter: jobsSealed.metadata.counter, direction: .response))
            #expect((try? JSONSerialization.jsonObject(with: jobsClear)) != nil)

            // GET /v1/events — same header rule; read the first sealed frame then cancel.
            var eventsRequest = URLRequest(url: base.appending(path: "v1/events"))
            eventsRequest.httpMethod = "GET"
            eventsRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            eventsRequest.timeoutInterval = 5
            let eventsSealed = try client.seal(Data(), method: "GET", route: "/v1/events")
            E2E.apply(eventsSealed, to: &eventsRequest)
            #expect(eventsRequest.httpBody == nil)
            #if canImport(Darwin)
            let (bytes, eventsResponse) = try await URLSession.shared.bytes(for: eventsRequest)
            #expect((eventsResponse as? HTTPURLResponse)?.statusCode == 200)
            var framed = Data()
            var sawFrame = false
            for try await byte in bytes {
                framed.append(byte)
                while framed.count >= 4 {
                    let length = framed.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
                    guard framed.count >= 4 + Int(length) else { break }
                    let envelope = framed.subdata(in: 4..<(4 + Int(length)))
                    framed.removeSubrange(0..<(4 + Int(length)))
                    let metadata = E2E.Metadata(method: "GET", route: "/v1/events", device: id,
                                                counter: eventsSealed.metadata.counter, direction: .response)
                    _ = try client.open(envelope, metadata: metadata)
                    sawFrame = true
                    break
                }
                if sawFrame { break }
            }
            #expect(sawFrame)
            #else
            // Linux URLSession has no bytes(for:); the GET jobs path above already exercises
            // URLSession with the envelope header against the live gateway.
            #expect(eventsRequest.value(forHTTPHeaderField: E2E.envelopeHeader) != nil)
            #endif
        }
    }

    @MainActor
    @Test func cleartextPairingIsRefusedAndASealedPairConsumesTheSecret() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let devices = Devices(file: folder.appending(path: "devices.json"))
        let gateway = Gateway(keys: mac)
        let desk = Desk(accounts: AccountStore(root: folder), store: JobStore(url: folder.appending(path: "oby.sqlite")))
        let api = API(desk: desk, devices: devices)
        api.gateway = gateway
        let app = Application(router: api.router(access: .gateway, e2eAllowed: true, gateway: gateway))
        let secret = try devices.openPairing()
        let pairingPath = devices.pairing.path
        let signing = P256.Signing.PrivateKey()
        let publicKey = signing.publicKey.x963Representation.base64EncodedString()
        let e2e = phone.publicKey.base64EncodedString()
        let proof = try signing.signature(for: Data("oby-e2e-register\n\(publicKey)\n\(e2e)".utf8))
            .derRepresentation.base64EncodedString()
        let clear = try JSONSerialization.data(withJSONObject: [
            "name": "Phone", "publicKey": publicKey, "e2ePublicKey": e2e, "e2eProof": proof, "pairingSecret": secret
        ])

        try await app.test(.live) { server in
            let port = try #require(server.port)
            let base = URL(string: "http://localhost:\(port)")!

            // Cleartext pairing must not cross the tunnel.
            var clearRequest = URLRequest(url: base.appending(path: "v1/pairing"))
            clearRequest.httpMethod = "POST"
            clearRequest.httpBody = clear
            clearRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let (_, clearResponse) = try await URLSession.shared.data(for: clearRequest)
            #expect((clearResponse as? HTTPURLResponse)?.statusCode == 401)
            #expect(FileManager.default.fileExists(atPath: pairingPath))

            // Sealed pairing to the QR's gateway key succeeds and consumes the secret.
            var sealedRequest = URLRequest(url: base.appending(path: "v1/pairing"))
            sealedRequest.httpMethod = "POST"
            let metadata = E2E.Metadata(method: "POST", route: "/v1/pairing", device: E2E.pairingDevice, counter: 1)
            let sealed = try E2E.seal(clear, to: mac.publicKey, metadata: metadata)
            E2E.apply((sealed, metadata), to: &sealedRequest)
            let (data, response) = try await URLSession.shared.data(for: sealedRequest)
            #expect((response as? HTTPURLResponse)?.statusCode == 200 || (response as? HTTPURLResponse)?.statusCode == 201)
            let answer = try JSONDecoder().decode([String: String].self, from: data)
            #expect(answer["publicKey"] == mac.publicKey.base64EncodedString())
            #expect(!FileManager.default.fileExists(atPath: pairingPath))
        }
    }
}
