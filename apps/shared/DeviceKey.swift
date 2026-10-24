// The watch publishes through the iPhone, or with its own pairing key (apps/watch/WatchLink.swift).
#if os(iOS) || os(macOS)
import CryptoKit
import Foundation
import LocalAuthentication
import OSLog
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

    /// What a device signs to change the runner's connections (docs/runner-api.md, "Connection"):
    /// another prefix than a publish's, so neither signature passes for the other.
    static func connectionMessage(action: String, signedAt: String) -> Data {
        Data("oby-connection\n\(action)\n\(signedAt)".utf8)
    }

    /// What a device signs to Confirm inbox item `item`, whose title is `title` (docs/runner-api.md,
    /// "POST /v1/inbox/{id}/answer", #776): its own prefix, so no publish or connection signature
    /// passes for a Confirm, and the item's id, so one tap confirms one item.
    static func confirmMessage(item: String, title: String, signedAt: String) -> Data {
        Data("oby-confirm\n\(item)\n\(title)\n\(signedAt)".utf8)
    }
}

/// The device's publishing key: the iPhone's behind Face ID, the Mac's behind Touch ID or the Mac's
/// password. It lives in the Secure Enclave and signs only after the owner's face, finger or
/// password, so the runner can tell a publish was approved on this device, by its owner, just now.
/// What the prompt says is each app's.
nonisolated enum DeviceKey {
    static var isAvailable: Bool { SecureEnclave.isAvailable }

    /// The public half, to register with the runner. Making the key doesn't ask for anything.
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

    /// Signs one change to the runner's connections with `context`, as `approve` signs a publish.
    static func approveConnection(action: String, device: String, context: LAContext) throws -> Approval {
        let signedAt = ISO8601DateFormatter().string(from: .now)
        let signature = try sign(Approval.connectionMessage(action: action, signedAt: signedAt), context: context)
        return Approval(device: device, action: action, signedAt: signedAt, signature: signature)
    }

    /// Signs the owner's Confirm of inbox item `item`: this asks for Face ID, with its title as the
    /// reason. It blocks until the user answers, so call it off the main actor.
    static func approveConfirm(item: String, title: String, device: String) throws -> Approval {
        let context = LAContext()
        context.localizedReason = title
        return try approveConfirm(item: item, title: title, device: device, context: context)
    }

    /// Signs the owner's Confirm of inbox item `item` with `context`, as `approve` signs a publish:
    /// `action` is the item's title, word for word (#776).
    static func approveConfirm(item: String, title: String, device: String, context: LAContext) throws -> Approval {
        let signedAt = ISO8601DateFormatter().string(from: .now)
        let signature = try sign(Approval.confirmMessage(item: item, title: title, signedAt: signedAt), context: context)
        return Approval(device: device, action: title, signedAt: signedAt, signature: signature)
    }

    /// ECDSA P-256 with SHA-256, DER, base64: what the runner checks.
    static func sign(_ message: Data, context: LAContext) throws -> String {
        try key(context: context).signature(for: message).derRepresentation.base64EncodedString()
    }

    #if os(macOS)
    // The Mac's login keychain, as its vault's (Engine/Vault.swift): it has no passcode class.
    private static let protection = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
    // Touch ID or the Mac's password (AGENTS.md, "The launch build"): a Mac mini or Studio has no
    // sensor, and a closed laptop can't reach its own.
    private static let presence = SecAccessControlCreateFlags.userPresence
    private static let noKey = "This Mac can't make its publishing key: it needs a login password."
    private static let named = "publishing"
    // A Touch ID-only key (`.biometryCurrentSet`, until 2026-10-23) was kept as `publish-key`: it
    // never signs after the password, so the Mac makes this one and registers it (MacDevice.idKey).
    private static let account = "publish-key.presence"
    private static let biometryOnly = "publish-key"
    #else
    private static let protection = kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly
    private static let presence = SecAccessControlCreateFlags.biometryCurrentSet
    private static let noKey = "This iPhone can't make a Face ID key."
    private static let named = "Face ID"
    private static let account = "publish-key"
    #endif

    private static func key(context: LAContext?) throws -> SecureEnclave.P256.Signing.PrivateKey {
        if let saved = read() {
            return try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: saved, authenticationContext: context)
        }
        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(nil, protection, [.privateKeyUsage, presence], &error) else {
            throw error?.takeRetainedValue() ?? RunnerError(message: noKey)
        }
        let key: SecureEnclave.P256.Signing.PrivateKey
        #if os(macOS)
        do {
            key = try SecureEnclave.P256.Signing.PrivateKey(accessControl: access, authenticationContext: context)
        } catch {
            throw RunnerError(message: noKey)
        }
        #else
        key = try SecureEnclave.P256.Signing.PrivateKey(accessControl: access, authenticationContext: context)
        #endif
        try save(key.dataRepresentation)
        #if os(macOS)
        // The Touch ID-only key it replaces: nothing signs with it any more.
        let deleted = SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.deskree.oby",
                                     kSecAttrAccount as String: biometryOnly] as CFDictionary)
        if deleted != errSecSuccess && deleted != errSecItemNotFound {
            Logger(subsystem: "com.deskree.oby", category: "device-key")
                .error("couldn't delete the Touch ID-only publishing key: \(deleted, privacy: .public)")
        }
        #endif
        return key
    }

    // The key itself never leaves the Secure Enclave: the Keychain keeps the wrapped blob only
    // this device's enclave can use.
    private static let item: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                              kSecAttrService as String: "com.deskree.oby",
                                              kSecAttrAccount as String: account]

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
        guard status == errSecSuccess else { throw RunnerError(message: "Couldn't keep the \(named) key (\(status)).") }
    }
}
#endif
