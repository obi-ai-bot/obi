import CryptoKit
import Foundation
import LocalAuthentication
import Security

/// The phone's approval for one publish, as the runner checks it (docs/runner-api.md).
nonisolated struct Approval: Encodable, Equatable, Sendable {
    var device: String
    var action: String
    var signedAt: String
    var signature: String

    static func message(job: String, action: String, signedAt: String) -> Data {
        Data("oby-publish\n\(job)\n\(action)\n\(signedAt)".utf8)
    }
}

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

/// The phone's publishing key. It lives in the Secure Enclave and signs only after Face ID, so the
/// runner can tell a publish was approved on this phone, by its owner, just now.
nonisolated enum DeviceKey {
    static var isAvailable: Bool { SecureEnclave.isAvailable }

    /// The public half, to register with the runner. Making the key doesn't ask for Face ID.
    static func publicKey() throws -> Data {
        try key(context: nil).publicKey.x963Representation
    }

    /// Signs one publish. This is what asks for Face ID, with the exact action as the reason.
    /// It blocks until the user answers, so call it off the main actor.
    static func approve(job: String, action: String, device: String) throws -> Approval {
        let context = LAContext()
        context.localizedReason = action
        let signedAt = ISO8601DateFormatter().string(from: .now)
        let signature = try key(context: context).signature(for: Approval.message(job: job, action: action, signedAt: signedAt))
        return Approval(device: device, action: action, signedAt: signedAt, signature: signature.derRepresentation.base64EncodedString())
    }

    /// Signs a Watch's pairing: Face ID, then the runner lets that watch's key in. `publicKey` is base64.
    /// It blocks until the user answers, so call it off the main actor.
    static func approvePairing(publicKey: String, device: String) throws -> PairingApproval {
        let context = LAContext()
        context.localizedReason = "Let your Apple Watch reach the runner without this iPhone"
        let signedAt = ISO8601DateFormatter().string(from: .now)
        let signature = try key(context: context).signature(for: PairingApproval.message(publicKey: publicKey, signedAt: signedAt))
        return PairingApproval(device: device, signedAt: signedAt, signature: signature.derRepresentation.base64EncodedString())
    }

    private static func key(context: LAContext?) throws -> SecureEnclave.P256.Signing.PrivateKey {
        if let saved = read() {
            return try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: saved, authenticationContext: context)
        }
        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly,
                                                           [.privateKeyUsage, .biometryCurrentSet], &error) else {
            throw error?.takeRetainedValue() ?? RunnerError(message: "This iPhone can't make a Face ID key.")
        }
        let key = try SecureEnclave.P256.Signing.PrivateKey(accessControl: access, authenticationContext: context)
        try save(key.dataRepresentation)
        return key
    }

    // The key itself never leaves the Secure Enclave: the Keychain keeps the wrapped blob only
    // this phone's enclave can use.
    private static let item: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                              kSecAttrService as String: "com.deskree.oby",
                                              kSecAttrAccount as String: "publish-key"]

    private static func read() -> Data? {
        var query = item
        query[kSecReturnData as String] = true
        var found: CFTypeRef?
        return SecItemCopyMatching(query as CFDictionary, &found) == errSecSuccess ? found as? Data : nil
    }

    private static func save(_ blob: Data) throws {
        var add = item
        add[kSecValueData as String] = blob
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw RunnerError(message: "Couldn't keep the Face ID key (\(status)).") }
    }
}
