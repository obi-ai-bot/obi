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
    func sealed(_ inner: [String: Any], to key: Curve25519.KeyAgreement.PublicKey) throws -> String {
        var sender = try HPKE.Sender(recipientKey: key, ciphersuite: .Curve25519_SHA256_ChachaPoly, info: Data("oby push v1".utf8))
        let ciphertext = try sender.seal(JSONSerialization.data(withJSONObject: inner))
        return (sender.encapsulatedKey + ciphertext).base64url
    }

    @Test func aSealedAlertOpensIntoItsTitleBodyThreadAndCategory() throws {
        let key = Curve25519.KeyAgreement.PrivateKey()
        let sealed = try sealed(["id": "n1", "at": 1_792_800_000, "title": "Run swift test?", "body": "Vault tests: swift test", "thread": "jobs",
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

    @Test func aReplayedAlertIsntNews() {
        let now: TimeInterval = 1_792_800_000
        func alert(_ id: String, at: TimeInterval) -> SealedPush.Alert {
            SealedPush.Alert(id: id, at: at, title: "t", body: "b", thread: "jobs", category: "job")
        }
        var seen: [String: TimeInterval] = ["gone": now - 8 * 86_400]
        #expect(SealedPush.isNews(alert("n1", at: now - 60), seen: &seen, now: now))
        #expect(!SealedPush.isNews(alert("n1", at: now - 60), seen: &seen, now: now + 5))
        #expect(!SealedPush.isNews(alert("n2", at: now - 86_400 - 1), seen: &seen, now: now))
        // A week on, an id is forgotten: its alert is over a day old by then anyway.
        #expect(seen.keys.sorted() == ["n1"])
    }

    /// The relay checks obid's pushes with it; obid never gets the pushSecret itself.
    @Test func thePushKeyIsAnHMACOfThePushSecret() throws {
        // The pushSecret's 32 bytes are 0 to 31; Python: hmac.new(bytes(range(32)), b"oby push key v1", "sha256").
        #expect(try PushRelay.pushKey("AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8") == "4OgUBy1cq0BmL6wBQqGNuJIR03CTAHndwEvtSkp7la4")
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
