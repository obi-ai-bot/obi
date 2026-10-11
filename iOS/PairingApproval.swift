import Foundation
import LocalAuthentication

/// The phone's approval for pairing one Apple Watch's key with the runner (docs/runner-api.md,
/// `POST /v1/watches`).
nonisolated struct PairingApproval: Encodable, Equatable, Sendable {
    var device: String
    var signedAt: String
    var signature: String

    static func message(publicKey: String, signedAt: String) -> Data {
        Data("oby-pair-watch\n\(publicKey)\n\(signedAt)".utf8)
    }
}

/// What only the phone's key does (the key itself is Shared/DeviceKey.swift; two files named DeviceKey.swift can't share a target).
extension DeviceKey {
    /// Signs a Watch's pairing: Face ID, then the runner lets that watch's key in. `publicKey` is base64.
    /// It blocks until the user answers, so call it off the main actor.
    nonisolated static func approvePairing(publicKey: String, device: String) throws -> PairingApproval {
        let context = LAContext()
        context.localizedReason = "Let your Apple Watch reach the runner without this iPhone"
        let signedAt = ISO8601DateFormatter().string(from: .now)
        let signature = try sign(PairingApproval.message(publicKey: publicKey, signedAt: signedAt), context: context)
        return PairingApproval(device: device, signedAt: signedAt, signature: signature)
    }
}
