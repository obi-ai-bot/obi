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

    /// The relay's payload: generic words, and the sealed alert.
    func pushed(_ sealed: String?, category: String = "") -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = "Oby"
        content.body = "Open Oby to see it."
        content.categoryIdentifier = category
        content.userInfo = sealed.map { ["sealed": $0, "item": "x/../../v1/jobs/j1/stop?"] } ?? ["job": "j1", "item": "j1-permission-p1"]
        return content
    }

    @Test func aSealedAlertOpensIntoItsTitleBodyThreadAndCategory() throws {
        let key = Curve25519.KeyAgreement.PrivateKey()
        let now: TimeInterval = 1_792_800_000
        let sealed = try sealed(["id": "n1", "at": now - 5, "title": "Run swift test?", "body": "Vault tests: swift test", "thread": "jobs",
                                 "category": "permissionRule", "job": "9f08fd10", "item": "9f08fd10-permission-p1"], to: key.publicKey)
        var seen: [String: TimeInterval] = [:]
        let content = SealedPush.shown(pushed(sealed), key: key, seen: &seen, now: now)
        #expect(content.title == "Run swift test?")
        #expect(content.body == "Vault tests: swift test")
        #expect(content.threadIdentifier == "jobs")
        #expect(content.categoryIdentifier == "permissionRule")
        #expect(content.userInfo as? [String: String] == ["id": "n1", "job": "9f08fd10", "item": "9f08fd10-permission-p1"])
        // Shown again (a replay), it says nothing new, quietly, and has no buttons.
        let again = SealedPush.shown(pushed(sealed), key: key, seen: &seen, now: now + 60)
        #expect(again.title == "Oby" && again.categoryIdentifier.isEmpty && again.userInfo.isEmpty)
        #expect(again.interruptionLevel == .passive && again.sound == nil)
    }

    /// Buttons and taps only ever come from what this iPhone opened: not from another key's alert,
    /// nor from a push with nothing sealed, whatever its category and userInfo say.
    @Test func onlyWhatOpensGetsButtons() throws {
        let other = try sealed(["id": "n2", "at": 1_792_800_000, "title": "t", "body": "b", "thread": "jobs", "category": "permission"],
                               to: Curve25519.KeyAgreement.PrivateKey().publicKey)
        var seen: [String: TimeInterval] = [:]
        for push in [pushed(other, category: "permission"), pushed(nil, category: "permission")] {
            let content = SealedPush.shown(push, key: Curve25519.KeyAgreement.PrivateKey(), seen: &seen)
            #expect(content.title == "Oby" && content.body == "Open Oby to see it.")
            #expect(content.categoryIdentifier.isEmpty && content.userInfo.isEmpty)
        }
    }

    /// obid's own vector (core/crates/obid/src/push.rs, `cryptokit_opens_what_obid_seals`, v2): what
    /// it sealed to the test iPhone's key opens here into the alert it sealed.
    @Test func whatObidSealsOpensHere() throws {
        let recipient = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: #require(Data(base64url: "H8N3pC2swtsoc14zwnS2w5bHYEEqREpOIxv21rPygBw")))
        let sealed = "yzzv3v2wiQKi22XvBmKaLVyZO7zv5rCO6ZKfOlkR2Ai6Tb_STHPyEjKJHTAkfAlwJmSBr2lqRetbeoz-6-nTUGP7YXs3rhK0cN2kVe4CY1AUJ9MJW1i6cjK4jQWwviFU3Y0neRoWsi6XkAMCQGGLYIL1ckm2uUr6FQfeZ2MAuHeq1pqlxHNPljCZ-XGpRQ73kif34Iw9guoNKB7djZSq9LpFtSbgQFNGBX3m5BCrSvUusYbbn5ELJTRPiXcGYwYdv9Dr5QCHQdPYaOzFbF3jFB98tZnDElz4R-68B5ZJZ0yAW_-sTqG-RsfPQd4z8r_NQfkoublPG-GL67p61NVyCJIpq4XJO_KWG0QVfQ"
        #expect(try SealedPush.open(sealed, with: recipient) == SealedPush.Alert(
            id: "5f0e8c1a3b2d4e6f8a9b0c1d2e3f4a5b", at: 1_800_000_000, title: "Run swift test?", body: "Android push: swift test --filter Push",
            thread: "jobs", category: "permission", job: "9f08fd10", item: "9f08fd10-permission-p1"))
        #expect(recipient.publicKey.rawRepresentation.base64url == "IWlFcnjzHXlyLYTNMzTi8Jn5yrH6_QwEDMtloT3gQiY")
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
        // The relay's fixed vector (docs/remote-access.md, "the keys"): the key is the pushSecret's 32 raw bytes.
        #expect(try PushRelay.pushKey("7x-XJBtltDkgComjTzh2aougWSW5C4fOPr7MutSocH4") == "vx_9SyYw9p7qPCxR8xHlDF8WlTOsR_LRA67SHhzpTHM")
        #expect(throws: (any Error).self) { try PushRelay.pushKey("c2hvcnQ") }
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
        // A plan's Approve lets the agent go on, as Allow does; Keep planning goes from the Lock Screen.
        let plan = try #require(Notifications.categories.first { $0.identifier == "plan" }).actions
        #expect(plan.map(\.title) == ["Approve", "Keep planning", "Open"])
        #expect(plan.filter { $0.options.contains(.authenticationRequired) }.map(\.identifier) == ["Approve"])
        #expect(plan.filter { Notifications.refusals.contains($0.identifier) }.map(\.identifier) == ["Keep planning"])
    }

    @Test func anAnswerNamesThePermissionTheAlertShowed() {
        #expect(Notifications.item(["id": "n1", "job": "9f08fd10", "item": "9f08fd10-permission-p1"]) == "9f08fd10-permission-p1")
        // No item (the Swift runner's alert), or one that isn't a plain id, answers nothing.
        #expect(Notifications.item(["job": "9f08fd10"]) == nil)
        #expect(Notifications.item(["item": "x/../../v1/jobs/j1/stop?"]) == nil)
        // And an id goes out as one path segment whatever it holds.
        #expect(Runner.inboxSegment("x/../j1?a#b") == "x%2F%2E%2E%2Fj1%3Fa%23b")
    }

    /// The Mac's link is read in `Phone.init`, where its didSet runs too (from nil): a launch keeps
    /// the sealing key and the relay's registration.
    @Test func aLaunchKeepsTheSealingKey() throws {
        let hadToken = GatewayTokenStore.read() != nil
        if !hadToken { try GatewayTokenStore.save("launch-test") }
        let savedLink = UserDefaults.standard.data(forKey: "mac.link")
        UserDefaults.standard.set(try MacLink(name: "My Mac", hostname: "oby-abcdefghijklmnop.tetrix.pro").encoded(), forKey: "mac.link")
        defer {
            if !hadToken { GatewayTokenStore.remove() }
            UserDefaults.standard.set(savedLink, forKey: "mac.link")
            SealedPush.forgetKey()
        }
        let key = try SealedPush.publicKey()
        #expect(Phone().link?.hostname == "oby-abcdefghijklmnop.tetrix.pro")
        #expect(try SealedPush.publicKey() == key)
    }

    @Test func aFailedAnswerSaysToOpenOby() {
        let content = Notifications.couldntAnswer(["id": "n1", "job": "9f08fd10", "item": "9f08fd10-permission-p1"]).content
        #expect(content.body == "Couldn't answer. Open Oby to see what it asks now.")
        #expect(content.categoryIdentifier == "job")
        #expect(content.userInfo as? [String: String] == ["job": "9f08fd10"])
    }
}
