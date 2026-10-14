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

    /// Pairing bootstrap: sealed to this gateway's public key before the device is registered.
    func openPairing(_ body: Data, metadata: E2E.Metadata) throws -> Data {
        try E2E.open(body, with: keys.privateKey, metadata: metadata)
    }

    func seal(_ body: Data, to publicKey: Data, metadata: E2E.Metadata) throws -> Data {
        try E2E.seal(body, to: publicKey, metadata: metadata, authenticatedBy: keys.privateKey)
    }
}

/// The remote-device boundary. Every request body is authenticated before API sees it and every
/// response body is encrypted before it leaves the runner. Pairing is sealed to the gateway key
/// from the QR (base HPKE); other routes need a registered device key. GET/HEAD envelopes may
/// arrive in `Oby-E2E-Envelope` because URLSession refuses a body on GET.
struct E2EGate<Context: RequestContext>: RouterMiddleware {
    let gateway: Gateway
    private let bodyLimit = 4 << 20

    @concurrent func handle(_ request: Request, context: Context,
                            next: @concurrent (Request, Context) async throws -> Response) async throws -> Response {
        if request.uri.path == "/v1/pairing" {
            return try await pairing(request, context: context, next: next)
        }
        guard request.headers[.obyE2EVersion] == E2E.version,
              let device = request.headers[.obyE2EDevice], !device.isEmpty,
              let counterText = request.headers[.obyE2ECounter], let counter = UInt64(counterText) else {
            throw APIError(.unauthorized, "This gateway requires an encrypted device envelope.")
        }
        let metadata = E2E.Metadata(method: request.method.rawValue, route: request.uri.string,
                                    device: device, counter: counter)
        var request = request
        do {
            let wire = try await Self.wire(from: &request, limit: bodyLimit)
            let clear = try gateway.open(wire, metadata: metadata)
            request.body = .init(buffer: ByteBuffer(bytes: clear))
            return try await sealResponse(try await run(request, context: context, next: next),
                                          device: device, metadata: metadata)
        } catch let error as E2E.Failure {
            throw APIError(.unauthorized, "The encrypted device message was rejected (\(String(describing: error))).")
        }
    }

    /// Pairing is sealed to the gateway public key the QR already pinned; the one-time secret stays
    /// inside the ciphertext. The device is not registered yet, so this uses base HPKE.
    private func pairing(_ request: Request, context: Context,
                         next: @concurrent (Request, Context) async throws -> Response) async throws -> Response {
        guard request.headers[.obyE2EVersion] == E2E.version,
              let device = request.headers[.obyE2EDevice], device == E2E.pairingDevice,
              let counterText = request.headers[.obyE2ECounter], let counter = UInt64(counterText) else {
            throw APIError(.unauthorized, "Pairing must be sealed to the Mac's gateway key from the QR.")
        }
        let metadata = E2E.Metadata(method: request.method.rawValue, route: request.uri.string,
                                    device: device, counter: counter)
        var request = request
        do {
            let wire = try await Self.wire(from: &request, limit: bodyLimit)
            let clear = try gateway.openPairing(wire, metadata: metadata)
            request.body = .init(buffer: ByteBuffer(bytes: clear))
            // Pairing answers stay cleartext so the client can pin the gateway key before it has a
            // session; the one-time secret was only in the request.
            return try await run(request, context: context, next: next)
        } catch let error as E2E.Failure {
            throw APIError(.unauthorized, "The encrypted device message was rejected (\(String(describing: error))).")
        }
    }

    private func run(_ request: Request, context: Context,
                     next: @concurrent (Request, Context) async throws -> Response) async throws -> Response {
        do {
            return try await next(request, context)
        } catch let error as APIError {
            return error.response
        } catch let error as HTTPError {
            return APIError(error.status, error.body ?? error.status.reasonPhrase).response
        } catch {
            return APIError(.internalServerError, error.localizedDescription).response
        }
    }

    private func sealResponse(_ response: Response, device: String, metadata: E2E.Metadata) throws -> Response {
        guard let publicKey = gateway.devicePublicKey(device) else { throw E2E.Failure.invalidKey }
        var response = response
        response.headers[.obyE2EVersion] = E2E.version
        response.headers[.contentType] = "application/octet-stream"
        response.body = response.body.map { buffer in
            let responseMetadata = E2E.Metadata(method: metadata.method, route: metadata.route,
                                                device: device, counter: metadata.counter, direction: .response)
            let sealed = try gateway.seal(Data(buffer.readableBytesView), to: publicKey, metadata: responseMetadata)
            return ByteBuffer(bytes: E2E.frame(sealed))
        }
        return response
    }

    private static func wire(from request: inout Request, limit: Int) async throws -> Data {
        let body = Data((try await request.collectBody(upTo: limit)).readableBytesView)
        return try E2E.wire(body: body, envelopeHeaderValue: request.headers[.obyE2EEnvelope])
    }
}
