// The watch publishes through the iPhone, or with its own pairing key (Watch/WatchLink.swift).
#if os(iOS) || os(macOS)
import CryptoKit
import Foundation
import LocalAuthentication
import Security

/// A device's approval for one publish, as the runner checks it (docs/runner-api.md).
nonisolated struct Approval: Encodable, Equatable, Sendable {
    var device: String
    var action: String
    var signedAt: String
    var signature: String

    static func message(job: String, action: String, signedAt: String) -> Data {
        Data("oby-publish\n\(job)\n\(action)\n\(signedAt)".utf8)
    }
}

/// The device's publishing key: the iPhone's behind Face ID, the Mac's behind Touch ID. It lives in
/// the Secure Enclave and signs only after the owner's face or finger, so the runner can tell a
/// publish was approved on this device, by its owner, just now. What the prompt says is each app's.
nonisolated enum DeviceKey {
    static var isAvailable: Bool { SecureEnclave.isAvailable }

    /// The public half, to register with the runner. Making the key doesn't ask for Face ID or Touch ID.
    static func publicKey() throws -> Data {
        try key(context: nil).publicKey.x963Representation
    }

    /// Signs one publish. This is what asks for Face ID, with the exact action as the reason.
    /// It blocks until the user answers, so call it off the main actor.
    static func approve(job: String, action: String, device: String) throws -> Approval {
        let context = LAContext()
        context.localizedReason = action
        return try approve(job: job, action: action, device: device, context: context)
    }

    /// Signs one publish with `context`: one the app has asked Touch ID or Face ID with already
    /// signs without asking again.
    static func approve(job: String, action: String, device: String, context: LAContext) throws -> Approval {
        let signedAt = ISO8601DateFormatter().string(from: .now)
        let signature = try sign(Approval.message(job: job, action: action, signedAt: signedAt), context: context)
        return Approval(device: device, action: action, signedAt: signedAt, signature: signature)
    }

    /// ECDSA P-256 with SHA-256, DER, base64: what the runner checks.
    static func sign(_ message: Data, context: LAContext) throws -> String {
        try key(context: context).signature(for: message).derRepresentation.base64EncodedString()
    }

    #if os(macOS)
    // The Mac's login keychain, as its vault's (Engine/Vault.swift): it has no passcode class.
    private static let protection = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
    private static let noKey = "This Mac can't make a Touch ID key. Publishing from it needs Touch ID."
    private static let biometry = "Touch ID"
    #else
    private static let protection = kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly
    private static let noKey = "This iPhone can't make a Face ID key."
    private static let biometry = "Face ID"
    #endif

    private static func key(context: LAContext?) throws -> SecureEnclave.P256.Signing.PrivateKey {
        if let saved = read() {
            return try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: saved, authenticationContext: context)
        }
        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(nil, protection, [.privateKeyUsage, .biometryCurrentSet], &error) else {
            throw error?.takeRetainedValue() ?? RunnerError(message: noKey)
        }
        let key: SecureEnclave.P256.Signing.PrivateKey
        #if os(macOS)
        do {
            key = try SecureEnclave.P256.Signing.PrivateKey(accessControl: access, authenticationContext: context)
        } catch {
            // No finger enrolled: Macs without a Touch ID sensor, or with none set up.
            throw RunnerError(message: noKey)
        }
        #else
        key = try SecureEnclave.P256.Signing.PrivateKey(accessControl: access, authenticationContext: context)
        #endif
        try save(key.dataRepresentation)
        return key
    }

    // The key itself never leaves the Secure Enclave: the Keychain keeps the wrapped blob only
    // this device's enclave can use.
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
        add[kSecAttrAccessible as String] = protection
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw RunnerError(message: "Couldn't keep the \(biometry) key (\(status)).") }
    }
}
#endif
