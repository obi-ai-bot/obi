#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation
#if canImport(Security)
import Security
#endif

/// The wire format for device-to-Mac traffic.  The method, route and counter are deliberately
/// outside the ciphertext so the gateway can apply its allowlist; they are authenticated as AAD.
/// The body itself is an HPKE (RFC 9180) base-mode message using X25519/HKDF-SHA256/ChaCha20-
/// Poly1305.  A fresh encapsulated key is used for every message.
public enum E2E {
    public static let version = "oby-e2e-1"
    public static let suite = HPKE.Ciphersuite.Curve25519_SHA256_ChachaPoly

    public static func frame(_ envelope: Data) -> Data {
        var length = UInt32(envelope.count).bigEndian
        return Data(bytes: &length, count: 4) + envelope
    }

    public static func unframe(_ data: Data) throws -> Data {
        guard data.count >= 4 else { throw Failure.invalidMessage }
        let length = data.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard data.count == 4 + Int(length) else { throw Failure.invalidMessage }
        return data.dropFirst(4)
    }

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
            let next = Self.nextCounter(for: counterKey)
            let metadata = Metadata(method: method, route: route, device: device, counter: next)
            return (try E2E.seal(body, to: gatewayPublicKey, metadata: metadata, authenticatedBy: keys.privateKey), metadata)
        }

        private static func nextCounter(for key: String) -> UInt64 {
            #if canImport(Security)
            let account = "e2e-counter-\(key)"
            var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                         kSecAttrService as String: "com.deskree.oby",
                                         kSecAttrAccount as String: account,
                                         kSecReturnData as String: true]
            var found: CFTypeRef?
            let old = SecItemCopyMatching(query as CFDictionary, &found) == errSecSuccess
                ? (found as? Data).flatMap { UInt64(String(decoding: $0, as: UTF8.self)) } ?? 0 : 0
            let next = old + 1
            let data = Data(String(next).utf8)
            query.removeValue(forKey: kSecReturnData as String)
            if old == 0 { query[kSecValueData as String] = data; _ = SecItemAdd(query as CFDictionary, nil) }
            else { _ = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary) }
            return next
            #else
            let next = UInt64(UserDefaults.standard.integer(forKey: key)) + 1
            UserDefaults.standard.set(next, forKey: key)
            return next
            #endif
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

    /// Per-device replay protection. Counters may arrive out of order within a bounded window,
    /// which is necessary when independent HTTP requests are in flight at once.
    public final class ReplayGuard: @unchecked Sendable {
        private struct Window: Codable {
            var highest: UInt64
            var counters: Set<UInt64>
        }

        private var windows: [String: Window] = [:]
        private let lock = NSLock()
        private let file: URL?
        private let capacity: Int

        public init(file: URL? = nil, capacity: Int = 4096) {
            self.file = file; self.capacity = capacity
            if let file, let data = try? Data(contentsOf: file) {
                if let saved = try? JSONDecoder().decode([String: Window].self, from: data) {
                    windows = saved
                } else if let legacy = try? JSONDecoder().decode([String: UInt64].self, from: data) {
                    // State written by the original strict-counter implementation remains a
                    // valid lower bound: the next request must still be newer than it.
                    windows = legacy.mapValues { Window(highest: $0, counters: [$0]) }
                }
            }
        }

        /// Check only. The caller must invoke `record` after authenticating the envelope.
        public func accept(_ metadata: Metadata) throws {
            guard metadata.counter > 0 else { throw Failure.replay }
            lock.lock(); defer { lock.unlock() }
            guard Self.acceptable(metadata.counter, in: windows[metadata.device]) else { throw Failure.replay }
        }

        public func record(_ metadata: Metadata) throws {
            lock.lock(); defer { lock.unlock() }
            guard metadata.counter > 0 else { throw Failure.replay }
            guard Self.acceptable(metadata.counter, in: windows[metadata.device]) else { throw Failure.replay }
            Self.insert(metadata.counter, into: &windows, device: metadata.device, capacity: capacity)
            guard let file else { return }
            let folder = file.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try JSONEncoder().encode(windows).write(to: file, options: .atomic)
        }

        /// Atomically verifies and records an authenticated message. Call this only after the
        /// envelope has been authenticated; keeping the check and write under one lock prevents
        /// two concurrent copies of one valid request from both reaching the API.
        public func acceptAndRecord(_ metadata: Metadata) throws {
            guard metadata.counter > 0 else { throw Failure.replay }
            lock.lock(); defer { lock.unlock() }
            guard Self.acceptable(metadata.counter, in: windows[metadata.device]) else { throw Failure.replay }
            Self.insert(metadata.counter, into: &windows, device: metadata.device, capacity: capacity)
            guard let file else { return }
            let folder = file.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try JSONEncoder().encode(windows).write(to: file, options: .atomic)
        }

        private static func acceptable(_ counter: UInt64, in window: Window?) -> Bool {
            guard let window else { return true }
            guard counter <= window.highest || window.highest < UInt64.max else {
                return true
            }
            let floor = window.highest > 64 ? window.highest - 63 : 1
            return counter >= floor && !window.counters.contains(counter)
        }

        private static func insert(_ counter: UInt64, into windows: inout [String: Window], device: String, capacity: Int) {
            var window = windows[device] ?? Window(highest: 0, counters: [])
            if counter > window.highest { window.highest = counter }
            let floor = window.highest > 64 ? window.highest - 63 : 1
            window.counters = window.counters.filter { $0 >= floor }
            window.counters.insert(counter)
            windows[device] = window
            if windows.count > capacity {
                let keep = windows.sorted { $0.value.highest > $1.value.highest }.prefix(capacity)
                windows = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
            }
        }
    }
}
