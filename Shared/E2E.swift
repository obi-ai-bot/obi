#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

/// The wire format for device-to-Mac traffic.  The method, route and counter are deliberately
/// outside the ciphertext so the gateway can apply its allowlist; they are authenticated as AAD.
/// The body itself is an HPKE (RFC 9180) base-mode message using X25519/HKDF-SHA256/ChaCha20-
/// Poly1305.  A fresh encapsulated key is used for every message.
public enum E2E {
    public static let version = "oby-e2e-1"
    public static let suite = HPKE.Ciphersuite.Curve25519_SHA256_ChachaPoly

    public struct KeyPair: Sendable {
        public let privateKey: Curve25519.KeyAgreement.PrivateKey

        public init() { privateKey = .init() }
        public init(rawPrivateKey: Data) throws { privateKey = try .init(rawRepresentation: rawPrivateKey) }
        public var publicKey: Data { privateKey.publicKey.rawRepresentation }
        public var privateKeyData: Data { privateKey.rawRepresentation }
    }

    public struct Metadata: Codable, Equatable, Sendable {
        public let method: String
        public let route: String
        public let device: String
        public let counter: UInt64

        public init(method: String, route: String, device: String, counter: UInt64) {
            self.method = method.uppercased(); self.route = route; self.device = device; self.counter = counter
        }

        var aad: Data { Data("\(version)\n\(method)\n\(route)\n\(device)\n\(counter)".utf8) }
    }

    public struct Envelope: Codable, Equatable, Sendable {
        public let version: String
        public let encapsulatedKey: Data
        public let ciphertext: Data

        public init(version: String = E2E.version, encapsulatedKey: Data, ciphertext: Data) {
            self.version = version; self.encapsulatedKey = encapsulatedKey; self.ciphertext = ciphertext
        }
        public func encoded() throws -> Data { try JSONEncoder().encode(self) }
        public static func decoded(_ data: Data) throws -> Envelope { try JSONDecoder().decode(self, from: data) }
    }

    public enum Failure: Error, Equatable { case unsupportedVersion; case replay; case invalidKey; case invalidMessage }

    public static func seal(_ plaintext: Data, to publicKey: Data, metadata: Metadata) throws -> Data {
        let key = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: publicKey)
        var sender = try HPKE.Sender(recipientKey: key, ciphersuite: suite, info: Data(version.utf8))
        let ciphertext = try sender.seal(plaintext, authenticating: metadata.aad)
        return try Envelope(encapsulatedKey: sender.encapsulatedKey, ciphertext: ciphertext).encoded()
    }

    public static func open(_ data: Data, with privateKey: Curve25519.KeyAgreement.PrivateKey, metadata: Metadata) throws -> Data {
        let envelope = try Envelope.decoded(data)
        guard envelope.version == version else { throw Failure.unsupportedVersion }
        var recipient = try HPKE.Recipient(privateKey: privateKey, ciphersuite: suite,
                                           info: Data(version.utf8), encapsulatedKey: envelope.encapsulatedKey)
        do { return try recipient.open(envelope.ciphertext, authenticating: metadata.aad) }
        catch { throw Failure.invalidMessage }
    }

    /// Per-device replay protection. Counters must increase strictly; a new device starts at 1.
    public final class ReplayGuard: @unchecked Sendable {
        private var last: [String: UInt64] = [:]
        private let lock = NSLock()
        public init() {}
        public func accept(_ metadata: Metadata) throws {
            guard metadata.counter > 0 else { throw Failure.replay }
            lock.lock(); defer { lock.unlock() }
            guard metadata.counter > (last[metadata.device] ?? 0) else { throw Failure.replay }
            last[metadata.device] = metadata.counter
        }
    }
}
