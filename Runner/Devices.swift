import Crypto
import Foundation
import HTTPTypes
@testable import ObyEngine

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

    struct GatewayToken: Codable, Equatable, Sendable {
        var id: String
        var name: String
        var created: Date
        var expiresAt: Date

        init(id: String, name: String, created: Date, expiresAt: Date) {
            self.id = id
            self.name = name
            self.created = created
            self.expiresAt = expiresAt
        }

        init(id: String, name: String, created: Date) {
            self.init(id: id, name: name, created: created, expiresAt: created.addingTimeInterval(Self.lifetime))
        }

        private enum CodingKeys: String, CodingKey { case id, name, created, expiresAt }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            let created = try values.decode(Date.self, forKey: .created)
            self.init(id: try values.decode(String.self, forKey: .id), name: try values.decode(String.self, forKey: .name),
                      created: created, expiresAt: try values.decodeIfPresent(Date.self, forKey: .expiresAt) ?? created.addingTimeInterval(Self.lifetime))
        }

        static let lifetime: TimeInterval = 30 * 24 * 60 * 60
    }

    private struct Saved: Codable {
        var devices: [Device] = []
        /// SHA-256 digests of gateway bearer tokens. The bearer itself never touches disk.
        var gatewayTokens: [String: GatewayToken] = [:]
        /// SHA-256 of each approval used, with when it was signed.
        var used: [String: Date] = [:]

        init(devices: [Device] = [], gatewayTokens: [String: GatewayToken] = [:], used: [String: Date] = [:]) {
            self.devices = devices
            self.gatewayTokens = gatewayTokens
            self.used = used
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            devices = try values.decodeIfPresent([Device].self, forKey: .devices) ?? []
            if let tokens = try? values.decodeIfPresent([String: GatewayToken].self, forKey: .gatewayTokens) {
                gatewayTokens = tokens
            } else {
                let old = try values.decodeIfPresent([String: Date].self, forKey: .gatewayTokens) ?? [:]
                gatewayTokens = old.mapValues { GatewayToken(id: UUID().uuidString.lowercased(), name: "Unknown device", created: $0) }
            }
            used = try values.decodeIfPresent([String: Date].self, forKey: .used) ?? [:]
        }
    }

    /// Records a gateway token after pairing. Only its digest is persisted.
    @discardableResult
    func addGatewayToken(digest: String, name: String = "iPhone", now: Date = .now) throws -> GatewayToken {
        guard digest.count == 64, digest.allSatisfy({ $0.isHexDigit }) else {
            throw APIError(.unprocessableContent, "That gateway token digest is invalid.")
        }
        let token = GatewayToken(id: UUID().uuidString.lowercased(), name: name, created: now)
        saved.gatewayTokens[digest] = token
        try save()
        return token
    }

    func acceptsGatewayToken(_ token: String, now: Date = .now) -> Bool {
        let digest = Pairing.digest(token)
        guard let record = saved.gatewayTokens[digest] else { return false }
        return record.expiresAt > now
    }

    func gatewayTokens() -> [(digest: String, token: GatewayToken)] {
        saved.gatewayTokens.map { ($0.key, $0.value) }.sorted { $0.token.created < $1.token.created }
    }

    @discardableResult
    func revokeGatewayToken(_ id: String) throws -> Bool {
        let before = saved.gatewayTokens.count
        saved.gatewayTokens = saved.gatewayTokens.filter { $0.value.id != id }
        guard saved.gatewayTokens.count != before else { return false }
        try save()
        return true
    }

    private let file: URL
    /// Beside `devices.json`: the owner touches it on the runner's machine to let one new phone register.
    let pairing: URL
    private var saved = Saved()

    init(file: URL) {
        self.file = file
        pairing = file.deletingLastPathComponent().appending(path: "pairing")
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
    /// A new key needs pairing open: `pairing` touched in the last 10 minutes, and that key uses it up.
    /// The tailnet header can't be the gate: agents share the runner's machine, so through its tailnet
    /// address they arrive as the owner. They can't touch `pairing`: OBY_HOME is empty in their bubblewrap.
    // ponytail: only as strong as that bubblewrap, so Linux only; a runner on a Mac needs its agents boxed too.
    func register(name: String, publicKey: String, now: Date = .now) throws -> String {
        guard Self.key(publicKey) != nil else {
            throw APIError(.unprocessableContent, "publicKey isn't a P-256 public key (X9.63, base64).")
        }
        if let known = saved.devices.first(where: { $0.publicKey == publicKey }) { return known.id }
        let opened = (try? FileManager.default.attributesOfItem(atPath: pairing.path))?[.modificationDate] as? Date
        guard let opened, now.timeIntervalSince(opened) < 600 else {
            throw APIError(.forbidden, "To add this phone, run `touch \(pairing.path)` on the runner, then try again within 10 minutes.")
        }
        let device = Device(id: UUID().uuidString.lowercased(), name: name, publicKey: publicKey, registered: now)
        saved.devices.append(device)
        try save()
        try? FileManager.default.removeItem(at: pairing)
        Logger.runner.notice("registered device \(device.id, privacy: .public): \(device.name, privacy: .public)")
        return device.id
    }

    /// Lets an approval through once: from a registered phone, signed by its key, for exactly the
    /// runner's own `action`, signed within two minutes, and never used before.
    func check(_ approval: Approval, job: String, action: String, now: Date = .now) throws {
        let message = Data("oby-publish\n\(job)\n\(approval.action)\n\(approval.signedAt)".utf8)
        let device = try signer(approval.device, of: message, signature: approval.signature)
        guard approval.action == action else {
            throw APIError(.forbidden, "The phone approved something else. Approve it again.")
        }
        try use(message, from: device, signedAt: approval.signedAt, now: now)
    }

    /// Lets a change to the connected apps through once (Runner/Broker.swift): the phone signed
    /// `"oby-connection\n<action>\n<signedAt>"` behind Face ID, within two minutes, for exactly the
    /// runner's own sentence. Agents reach the API as the owner, so the tailnet header can't be the gate.
    func checkConnection(_ approval: Approval, action: String, now: Date = .now) throws {
        let message = Data("oby-connection\n\(approval.action)\n\(approval.signedAt)".utf8)
        let device = try signer(approval.device, of: message, signature: approval.signature)
        guard approval.action == action else {
            throw APIError(.forbidden, "The phone approved something else. Approve it again.")
        }
        try use(message, from: device, signedAt: approval.signedAt, now: now)
    }

    /// Lets a Watch's pairing through once (Runner/Watches.swift): the phone signed
    /// `"oby-pair-watch\n<the Watch's public key>\n<signedAt>"` behind Face ID, within two minutes.
    func checkPairing(_ approval: PairingApproval, publicKey: String, now: Date = .now) throws {
        let message = Data("oby-pair-watch\n\(publicKey)\n\(approval.signedAt)".utf8)
        let device = try signer(approval.device, of: message, signature: approval.signature)
        try use(message, from: device, signedAt: approval.signedAt, now: now)
    }

    /// The registered phone whose key signed `message`.
    private func signer(_ id: String, of message: Data, signature: String) throws -> Device {
        guard let device = saved.devices.first(where: { $0.id == id }), let key = Self.key(device.publicKey) else {
            throw APIError(.forbidden, "That device isn't registered with this runner.")
        }
        guard let der = Data(base64Encoded: signature), let signature = try? P256.Signing.ECDSASignature(derRepresentation: der),
              key.isValidSignature(signature, for: message) else {
            throw APIError(.forbidden, "The signature doesn't match the device's key.")
        }
        return device
    }

    /// Uses up a signed message: signed within two minutes and never used before.
    private func use(_ message: Data, from device: Device, signedAt text: String, now: Date) throws {
        guard let signedAt = try? Date(text, strategy: .iso8601), abs(signedAt.timeIntervalSince(now)) <= 120 else {
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
