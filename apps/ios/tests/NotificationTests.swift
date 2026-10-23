import CryptoKit
import Foundation
import Testing
import UserNotifications
@testable import Oby

/// Oby's sealed alerts (apps/ios/push/SealedPush.swift, opened by the push extension) and a
/// permission's answers from its alert (#865, apps/ios/app/Notifications.swift).
@MainActor
struct NotificationTests {
    /// Seals as obid does: HPKE base mode, X25519, HKDF-SHA256, ChaCha20-Poly1305, info "oby push v1",
    /// then base64url of the encapsulated key followed by the ciphertext.
    func sealed(_ inner: [String: String], to key: Curve25519.KeyAgreement.PublicKey) throws -> String {
        var sender = try HPKE.Sender(recipientKey: key, ciphersuite: .Curve25519_SHA256_ChachaPoly, info: Data("oby push v1".utf8))
        let ciphertext = try sender.seal(JSONSerialization.data(withJSONObject: inner))
        return (sender.encapsulatedKey + ciphertext).base64url
    }

    @Test func aSealedAlertOpensIntoItsTitleBodyThreadAndCategory() throws {
        let key = Curve25519.KeyAgreement.PrivateKey()
        let sealed = try sealed(["id": "n1", "title": "Run swift test?", "body": "Vault tests: swift test", "thread": "jobs",
                                 "category": "permissionRule", "job": "9f08fd10", "item": "p1a2b3c"], to: key.publicKey)
        let content = UNMutableNotificationContent()
        content.title = "Oby"
        content.body = "Open Oby to see it."
        SealedPush.show(try SealedPush.open(sealed, with: key), in: content)
        #expect(content.title == "Run swift test?")
        #expect(content.body == "Vault tests: swift test")
        #expect(content.threadIdentifier == "jobs")
        #expect(content.categoryIdentifier == "permissionRule")
        #expect(content.userInfo as? [String: String] == ["id": "n1", "job": "9f08fd10", "item": "p1a2b3c"])
        // Another iPhone's key opens nothing: the relay's generic words stay.
        #expect(throws: (any Error).self) { try SealedPush.open(sealed, with: Curve25519.KeyAgreement.PrivateKey()) }
    }

    /// obid's own vector (core/crates/obid/src/push.rs, `cryptokit_opens_what_obid_seals`): what it
    /// sealed to the test iPhone's key opens here into the alert it sealed.
    @Test func whatObidSealsOpensHere() throws {
        let recipient = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: #require(Data(base64url: "H8N3pC2swtsoc14zwnS2w5bHYEEqREpOIxv21rPygBw")))
        let sealed = "IslSF4EeX1qFjKGhEE-Ak7s1ol-lz1czJtqklgSPkT0M-rtgmAoFzjgF92N2FWipbKpP44rc4aTEyQFJzmgNSl5q7NDtqkNfOttqBfBjrUnFwvFAnRspL-RCt-aiIvAFPQpDnMWQv7HlIYTRJhZBxYNoK_MdvT9BWloJ47U46wpgynhs4-bbQsDddUpU3aL55KH-KVzyS_3V2rbBgwx5HdhTKUDwonvE6XL2bu1sWnjj_uOVQrdccjVGxzHBS9Udf1bN_jF0ktTZ25PRskc1q_9PoWo-DZhmOsY4IeNt1EiXhZ65"
        #expect(try SealedPush.open(sealed, with: recipient) == SealedPush.Alert(
            id: "9f08fd10", title: "Run swift test?", body: "Android push: swift test --filter Push", thread: "jobs",
            category: "permission", job: "9f08fd10", item: "9f08fd10-permission-p1"))
        #expect(recipient.publicKey.rawRepresentation.base64url == "IWlFcnjzHXlyLYTNMzTi8Jn5yrH6_QwEDMtloT3gQiY")
    }

    @Test func allowAndAlwaysAllowNeedAnUnlockedPhone() throws {
        let actions = try #require(Notifications.categories.first { $0.identifier == "permissionRule" }).actions
        #expect(actions.map(\.title) == ["Allow", "Always allow", "Deny", "Open"])
        #expect(actions.filter { $0.options.contains(.authenticationRequired) }.map(\.identifier) == ["Allow", "Always allow"])
        // Deny lets nothing run: from the Lock Screen, in the background.
        #expect(actions.first { $0.identifier == "Deny" }?.options == [.destructive])
    }

    @Test func aPermissionWithoutARuleOffersNoAlwaysAllow() throws {
        let actions = try #require(Notifications.categories.first { $0.identifier == "permission" }).actions
        #expect(actions.map(\.title) == ["Allow", "Deny", "Open"])
    }

    @Test func anAnswerNamesThePermissionTheAlertShowed() {
        let shown: [AnyHashable: Any] = ["id": "n1", "job": "9f08fd10", "item": "9f08fd10-permission-p1"]
        #expect(Notifications.item(answering: "Always allow", shown) == "9f08fd10-permission-p1")
        #expect(Notifications.item(answering: "open", shown) == nil)
        #expect(Notifications.item(answering: "Allow", ["job": "9f08fd10"]) == nil)
    }

    @Test func aFailedAnswerSaysToOpenOby() {
        let content = Notifications.couldntAnswer(["id": "n1", "job": "9f08fd10", "item": "9f08fd10-permission-p1"]).content
        #expect(content.body == "Couldn't answer. Open Oby to see what it asks now.")
        #expect(content.categoryIdentifier == "job")
        #expect(content.userInfo as? [String: String] == ["job": "9f08fd10"])
    }
}
