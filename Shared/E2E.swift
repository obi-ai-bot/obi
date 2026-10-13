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
        public enum Direction: String, Codable, Sendable { case request, response }
        public let method: String
        public let route: String
        public let device: String
        public let counter: UInt64
        public let direction: Direction

        public init(method: String, route: String, device: String, counter: UInt64, direction: Direction = .request) {
            self.method = method.uppercased(); self.route = route; self.device = device; self.counter = counter; self.direction = direction
        }

        var aad: Data { Data("\(version)\n\(direction.rawValue)\n\(method)\n\(route)\n\(device)\n\(counter)".utf8) }
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

    /// Client-side session for the Mac gateway. The counter is persisted by key so a relaunch
    /// cannot reuse a request number. The Mac's public key comes from the pairing record.
    public final class Client: @unchecked Sendable {
        public let device: String
        public let keys: KeyPair
        public let gatewayPublicKey: Data
        private let counterKey: String
        private let lock = NSLock()

        public init(device: String, keys: KeyPair, gatewayPublicKey: Data, counterKey: String) throws {
            guard gatewayPublicKey.count == 32 else { throw Failure.invalidKey }
            _ = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: gatewayPublicKey)
            self.device = device; self.keys = keys; self.gatewayPublicKey = gatewayPublicKey; self.counterKey = counterKey
        }

        public func seal(_ body: Data, method: String, route: String) throws -> (body: Data, metadata: Metadata) {
            lock.lock(); defer { lock.unlock() }
            let next = UserDefaults.standard.integer(forKey: counterKey) + 1
            UserDefaults.standard.set(next, forKey: counterKey)
            let metadata = Metadata(method: method, route: route, device: device, counter: UInt64(next))
            return (try E2E.seal(body, to: gatewayPublicKey, metadata: metadata, authenticatedBy: keys.privateKey), metadata)
        }

        public func open(_ body: Data, metadata: Metadata) throws -> Data {
            guard metadata.device == device, metadata.direction == .response else { throw Failure.invalidMessage }
            return try E2E.open(body, with: keys.privateKey, metadata: metadata, authenticatedBy: Curve25519.KeyAgreement.PublicKey(rawRepresentation: gatewayPublicKey))
        }
    }

    public enum Failure: Error, Equatable { case unsupportedVersion; case replay; case invalidKey; case invalidMessage }

    public static func seal(_ plaintext: Data, to publicKey: Data, metadata: Metadata,
                            authenticatedBy senderKey: Curve25519.KeyAgreement.PrivateKey? = nil) throws -> Data {
        let key = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: publicKey)
        var sender: HPKE.Sender
        if let senderKey {
            sender = try HPKE.Sender(recipientKey: key, ciphersuite: suite, info: Data(version.utf8), authenticatedBy: senderKey)
        } else {
            sender = try HPKE.Sender(recipientKey: key, ciphersuite: suite, info: Data(version.utf8))
        }
        let ciphertext = try sender.seal(plaintext, authenticating: metadata.aad)
        return try Envelope(encapsulatedKey: sender.encapsulatedKey, ciphertext: ciphertext).encoded()
    }

    public static func open(_ data: Data, with privateKey: Curve25519.KeyAgreement.PrivateKey, metadata: Metadata,
                            authenticatedBy senderKey: Curve25519.KeyAgreement.PublicKey? = nil) throws -> Data {
        let envelope = try Envelope.decoded(data)
        guard envelope.version == version else { throw Failure.unsupportedVersion }
        var recipient: HPKE.Recipient
        if let senderKey {
            recipient = try HPKE.Recipient(privateKey: privateKey, ciphersuite: suite,
                                           info: Data(version.utf8), encapsulatedKey: envelope.encapsulatedKey,
                                           authenticatedBy: senderKey)
        } else {
            recipient = try HPKE.Recipient(privateKey: privateKey, ciphersuite: suite,
                                           info: Data(version.utf8), encapsulatedKey: envelope.encapsulatedKey)
        }
        do { return try recipient.open(envelope.ciphertext, authenticating: metadata.aad) }
        catch { throw Failure.invalidMessage }
    }

    /// Per-device replay protection. Counters must increase strictly; a new device starts at 1.
    public final class ReplayGuard: @unchecked Sendable {
        private var last: [String: UInt64] = [:]
        private let lock = NSLock()
        private let file: URL?
        private let capacity: Int

        public init(file: URL? = nil, capacity: Int = 4096) {
            self.file = file; self.capacity = capacity
            if let file, let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode([String: UInt64].self, from: data) {
                last = saved
            }
        }

        /// Check only. The caller must invoke `record` after authenticating the envelope.
        public func accept(_ metadata: Metadata) throws {
            guard metadata.counter > 0 else { throw Failure.replay }
            lock.lock(); defer { lock.unlock() }
            guard metadata.counter > (last[metadata.device] ?? 0) else { throw Failure.replay }
        }

        public func record(_ metadata: Metadata) throws {
            lock.lock(); defer { lock.unlock() }
            last[metadata.device] = metadata.counter
            if last.count > capacity {
                let keep = last.sorted { $0.value > $1.value }.prefix(capacity)
                last = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
            }
            guard let file else { return }
            let folder = file.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try JSONEncoder().encode(last).write(to: file, options: .atomic)
        }

        /// Atomically verifies and records an authenticated message. Call this only after the
        /// envelope has been authenticated; keeping the check and write under one lock prevents
        /// two concurrent copies of one valid request from both reaching the API.
        public func acceptAndRecord(_ metadata: Metadata) throws {
            guard metadata.counter > 0 else { throw Failure.replay }
            lock.lock(); defer { lock.unlock() }
            guard metadata.counter > (last[metadata.device] ?? 0) else { throw Failure.replay }
            last[metadata.device] = metadata.counter
            if last.count > capacity {
                let keep = last.sorted { $0.value > $1.value }.prefix(capacity)
                last = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
            }
            guard let file else { return }
            let folder = file.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try JSONEncoder().encode(last).write(to: file, options: .atomic)
        }
    }
}
