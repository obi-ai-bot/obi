import Foundation
import Hummingbird
import HTTPTypes
import NIOCore
import ObyShared
@testable import ObyEngine
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// The cryptographic edge of the Mac gateway. HTTP routing remains responsible for the clear
/// method and route allowlist; this type is the only place that turns a device body into plaintext
/// and it never logs or serializes that plaintext. The HTTP adapter must call `open` before handing
/// a request to API and `seal` before returning its response.
final class Gateway: @unchecked Sendable {
    let keys: E2E.KeyPair
    private let replay: E2E.ReplayGuard
    private let lock = NSLock()
    private var devices: [String: Curve25519.KeyAgreement.PublicKey]

    init(keys: E2E.KeyPair = .init(), replayFile: URL? = nil,
         devices: [String: Data] = [:]) {
        self.keys = keys
        self.replay = E2E.ReplayGuard(file: replayFile)
        self.devices = devices.compactMapValues { try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: $0) }
    }

    /// Loads the Mac's static key from the runner vault, creating it once. On macOS this is the
    /// login keychain-backed vault; on Linux it is the runner-only vault file.
    static func persisted(replayFile: URL? = nil, devices: [String: Data] = [:]) throws -> Gateway {
        let name = "e2e-gateway-private"
        let keys: E2E.KeyPair
        if let saved = try Vault.shared.store.value(name), let raw = Data(base64Encoded: saved) {
            keys = try E2E.KeyPair(rawPrivateKey: raw)
        } else {
            keys = E2E.KeyPair()
            try Vault.shared.add(keys.privateKeyData.base64EncodedString(), as: name)
        }
        return Gateway(keys: keys, replayFile: replayFile, devices: devices)
    }

    var publicKey: Data { keys.publicKey }

    func register(device: String, publicKey: String) throws {
        guard let data = Data(base64Encoded: publicKey), let key = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: data) else {
            throw APIError(.unprocessableContent, "e2ePublicKey isn't an X25519 public key (base64).")
        }
        lock.lock(); defer { lock.unlock() }
        devices[device] = key
    }

    func devicePublicKey(_ device: String) -> Data? {
        lock.lock(); defer { lock.unlock() }
        return devices[device]?.rawRepresentation
    }

    func open(_ body: Data, metadata: E2E.Metadata) throws -> Data {
        lock.lock()
        let device = devices[metadata.device]
        lock.unlock()
        guard let device else { throw E2E.Failure.invalidKey }
        let clear = try E2E.open(body, with: keys.privateKey, metadata: metadata, authenticatedBy: device)
        try replay.acceptAndRecord(metadata)
        return clear
    }

    func seal(_ body: Data, to publicKey: Data, metadata: E2E.Metadata) throws -> Data {
        try E2E.seal(body, to: publicKey, metadata: metadata, authenticatedBy: keys.privateKey)
    }
}

/// The remote-device boundary. Every request body is authenticated before API sees it and every
/// response body is encrypted before it leaves the runner. Pairing and the owner-only API remain
/// on the ordinary runner port; this middleware is installed on the device gateway port.
struct E2EGate<Context: RequestContext>: RouterMiddleware {
    let gateway: Gateway
    private let bodyLimit = 4 << 20

    @concurrent func handle(_ request: Request, context: Context,
                            next: @concurrent (Request, Context) async throws -> Response) async throws -> Response {
        guard request.headers[.obyE2EVersion] == E2E.version,
              let device = request.headers[.obyE2EDevice], !device.isEmpty,
              let counterText = request.headers[.obyE2ECounter], let counter = UInt64(counterText) else {
            throw APIError(.unauthorized, "This gateway requires an encrypted device envelope.")
        }
        let metadata = E2E.Metadata(method: request.method.rawValue, route: request.uri.string,
                                    device: device, counter: counter)
        var request = request
        do {
            let wire = try await request.collectBody(upTo: bodyLimit)
            let clear = try gateway.open(Data(wire.readableBytesView), metadata: metadata)
            request.body = .init(buffer: ByteBuffer(bytes: clear))
            var response = try await next(request, context)
            guard let publicKey = gateway.devicePublicKey(device) else { throw E2E.Failure.invalidKey }
            let responseMetadata = E2E.Metadata(method: metadata.method, route: metadata.route,
                                                device: device, counter: counter, direction: .response)
            response.headers[.obyE2EVersion] = E2E.version
            response.headers[.contentType] = "application/octet-stream"
            response.body = response.body.map { buffer in
                ByteBuffer(bytes: try gateway.seal(Data(buffer.readableBytesView), to: publicKey, metadata: responseMetadata))
            }
            return response
        } catch let error as E2E.Failure {
            throw APIError(.unauthorized, "The encrypted device message was rejected (\(String(describing: error))).")
        }
    }
}
