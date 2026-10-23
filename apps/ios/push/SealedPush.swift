import CryptoKit
import Foundation
import Security
import UserNotifications

/// Oby's sealed alerts. Deskree's relay keeps this iPhone's APNs token and forwards what obid sends
/// without reading it: obid seals each alert with HPKE to this iPhone's X25519 key, and the
/// Notification Service Extension (NotificationService.swift) opens it on the phone. The private key
/// never leaves this iPhone, and nothing opened is logged. In the app and the extension both.
nonisolated enum SealedPush {
    /// What obid seals: the alert's words, its thread and category, and what a tap opens.
    struct Alert: Decodable, Equatable {
        var id: String
        var title: String
        var body: String
        var thread: String
        var category: String
        var job: String?
        var conversation: String?
        /// The inbox item it's about; on a permission's alert, the permission's id (#865).
        var item: String?
    }

    static let info = Data("oby push v1".utf8)

    /// Opens `sealed`: base64url of HPKE's encapsulated key (32 bytes) followed by the ciphertext.
    static func open(_ sealed: String, with key: Curve25519.KeyAgreement.PrivateKey) throws -> Alert {
        guard let data = Data(base64url: sealed), data.count > 32 else { throw CryptoKitError.incorrectParameterSize }
        var recipient = try HPKE.Recipient(privateKey: key, ciphersuite: .Curve25519_SHA256_ChachaPoly, info: info,
                                           encapsulatedKey: Data(data.prefix(32)))
        return try JSONDecoder().decode(Alert.self, from: recipient.open(data.dropFirst(32)))
    }

    /// Puts the opened alert in place of the relay's generic "Open Oby to see it."
    static func show(_ alert: Alert, in content: UNMutableNotificationContent) {
        content.title = alert.title
        content.body = alert.body
        content.threadIdentifier = alert.thread
        content.categoryIdentifier = alert.category
        content.userInfo = ["id": alert.id, "job": alert.job, "conversation": alert.conversation, "item": alert.item]
            .compactMapValues { $0 }
    }

    // MARK: The key

    /// The sealing key, made the first time it's asked for. Unpairing forgets it (Notifications.swift).
    static func key() throws -> Curve25519.KeyAgreement.PrivateKey {
        if let saved = savedKey() { return saved }
        let key = Curve25519.KeyAgreement.PrivateKey()
        try Keychain.save(key.rawRepresentation, as: keyAccount, group: Keychain.shared)
        return key
    }

    /// What obid seals to: the key's public half, raw, base64url.
    static func publicKey() throws -> String { try key().publicKey.rawRepresentation.base64url }

    static func savedKey() -> Curve25519.KeyAgreement.PrivateKey? {
        Keychain.read(keyAccount, group: Keychain.shared).flatMap { try? .init(rawRepresentation: $0) }
    }

    static func forgetKey() { Keychain.remove(keyAccount, group: Keychain.shared) }

    private static let keyAccount = "seal-key"

    /// Generic-password items on this device only, readable after the first unlock: an alert comes
    /// in on a locked phone. `shared` is the one Keychain group the extension can read (its
    /// entitlements list only that group); with no group, an item stays in the app's own.
    enum Keychain {
        static let shared = Bundle.main.object(forInfoDictionaryKey: "ObyPushKeychainGroup") as? String

        private static func query(_ account: String, group: String?) -> [String: Any] {
            var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                        kSecAttrService as String: "com.deskree.oby.push", kSecAttrAccount as String: account]
            if let group { query[kSecAttrAccessGroup as String] = group }
            return query
        }

        static func read(_ account: String, group: String?) -> Data? {
            var result: AnyObject?
            let status = SecItemCopyMatching(query(account, group: group).merging([kSecReturnData as String: true]) { $1 } as CFDictionary, &result)
            return status == errSecSuccess ? result as? Data : nil
        }

        static func save(_ data: Data, as account: String, group: String?) throws {
            remove(account, group: group)
            let item = query(account, group: group).merging([kSecValueData as String: data,
                                                             kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]) { $1 }
            let status = SecItemAdd(item as CFDictionary, nil)
            guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        }

        static func remove(_ account: String, group: String?) {
            SecItemDelete(query(account, group: group) as CFDictionary)
        }
    }
}

nonisolated extension Data {
    init?(base64url text: String) {
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        self.init(base64Encoded: base64)
    }

    var base64url: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
