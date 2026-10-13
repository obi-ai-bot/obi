import Foundation
import ObyShared

/// The cryptographic edge of the Mac gateway. HTTP routing remains responsible for the clear
/// method and route allowlist; this type is the only place that turns a device body into plaintext
/// and it never logs or serializes that plaintext. The HTTP adapter must call `open` before handing
/// a request to API and `seal` before returning its response.
struct Gateway: Sendable {
    let keys: E2E.KeyPair
    private let replay = E2E.ReplayGuard()

    init(keys: E2E.KeyPair = .init()) { self.keys = keys }

    var publicKey: Data { keys.publicKey }

    func open(_ body: Data, metadata: E2E.Metadata) throws -> Data {
        try replay.accept(metadata)
        return try E2E.open(body, with: keys.privateKey, metadata: metadata)
    }

    func seal(_ body: Data, to publicKey: Data, metadata: E2E.Metadata) throws -> Data {
        try E2E.seal(body, to: publicKey, metadata: metadata)
    }
}
