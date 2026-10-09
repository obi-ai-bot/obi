import Crypto
import Foundation
import HTTPTypes
@testable import ObyEngine
#if canImport(OSLog)
import OSLog
#endif

/// The phones that may approve publishing, each by its Secure Enclave key, kept in `devices.json`
/// with the approvals already used, so none works twice. The runner has no Touch ID: a phone's
/// signature, made behind Face ID, stands in for it.
@MainActor
final class Devices {
    struct Device: Codable {
        var id: String
        var name: String
        /// P-256, X9.63 (65 bytes, uncompressed), base64.
        var publicKey: String
        var registered: Date
    }

    private struct Saved: Codable {
        var devices: [Device] = []
        /// SHA-256 of each approval used, with when it was signed.
        var used: [String: Date] = [:]
    }

    private let file: URL
    private var saved = Saved()

    init(file: URL) {
        self.file = file
        if let data = try? Data(contentsOf: file) {
            do {
                saved = try Self.decoder.decode(Saved.self, from: data)
            } catch {
                Logger.runner.error("can't read \(file.path, privacy: .public): no device can approve until one registers again")
            }
        }
        for device in saved.devices { Logger.runner.notice("device \(device.id, privacy: .public): \(device.name, privacy: .public)") }
    }

    /// Adds a phone's publishing key and returns its id. A key it already knows keeps its id, so the
    /// app can register every time it connects and always holds an id this runner knows.
    func register(name: String, publicKey: String) throws -> String {
        guard Self.key(publicKey) != nil else {
            throw APIError(.unprocessableContent, "publicKey isn't a P-256 public key (X9.63, base64).")
        }
        if let known = saved.devices.first(where: { $0.publicKey == publicKey }) { return known.id }
        let device = Device(id: UUID().uuidString.lowercased(), name: name, publicKey: publicKey, registered: .now)
        saved.devices.append(device)
        try save()
        Logger.runner.notice("registered device \(device.id, privacy: .public): \(device.name, privacy: .public)")
        return device.id
    }

    /// Lets an approval through once: from a registered phone, signed by its key, for exactly the
    /// runner's own `action`, signed within two minutes, and never used before.
    func check(_ approval: Approval, job: String, action: String, now: Date = .now) throws {
        guard let device = saved.devices.first(where: { $0.id == approval.device }), let key = Self.key(device.publicKey) else {
            throw APIError(.forbidden, "That device isn't registered with this runner.")
        }
        let message = Data("oby-publish\n\(job)\n\(approval.action)\n\(approval.signedAt)".utf8)
        guard let der = Data(base64Encoded: approval.signature), let signature = try? P256.Signing.ECDSASignature(derRepresentation: der),
              key.isValidSignature(signature, for: message) else {
            throw APIError(.forbidden, "The signature doesn't match the device's key.")
        }
        guard approval.action == action else {
            throw APIError(.forbidden, "The phone approved something else. Approve it again.")
        }
        guard let signedAt = try? Date(approval.signedAt, strategy: .iso8601), abs(signedAt.timeIntervalSince(now)) <= 120 else {
            throw APIError(.forbidden, "The approval is more than two minutes old. Approve it again.")
        }
        // The signed message, not the signature: an ECDSA signature can be rewritten into another valid one.
        let hash = SHA256.hash(data: Data(device.id.utf8) + message).map { String(format: "%02x", $0) }.joined()
        saved.used = saved.used.filter { now.timeIntervalSince($0.value) < 600 }
        guard saved.used[hash] == nil else {
            throw APIError(.forbidden, "That approval was already used. Approve it again.")
        }
        saved.used[hash] = signedAt
        try save()
    }

    private static func key(_ base64: String) -> P256.Signing.PublicKey? {
        Data(base64Encoded: base64).flatMap { try? P256.Signing.PublicKey(x963Representation: $0) }
    }

    private func save() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(saved).write(to: file, options: .atomic)
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

extension Logger {
    nonisolated static let runner = Logger(subsystem: "com.deskree.oby", category: "runner")
}
