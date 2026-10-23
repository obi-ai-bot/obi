import CryptoKit
import LocalAuthentication
import OSLog
import UIKit
import UserNotifications

/// The alerts obid sends when something needs you or something you started finished. They come
/// through Deskree's relay, sealed (PushRelay below; the extension in apps/ios/push opens them):
/// "Ready to publish" with Publish and Open, a failed or interrupted job with Open, a permission
/// with Allow, Always allow (when a rule can be saved), Deny and Open (#865). Tapping one opens its
/// job or conversation; Publish brings Oby forward, where Face ID signs it as it does in the app.
final class Notifications: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    let phone = Phone()

    static let publish = "publish"
    static let open = "open"
    /// A publish the watch asked for while Oby was in the background (apps/ios/app/WatchRelay.swift):
    /// Face ID can't come up then, so this notification's Publish does it.
    static let approve = "approve"

    /// The runner's `category`: "ready" for a job waiting for Publish, "job" for the rest, and a
    /// permission's "permission", or "permissionRule" when Always allow can save a rule. A
    /// permission's actions are named for the inbox's answers (`answers`).
    nonisolated static let answers: Set<String> = ["Allow", "Always allow", "Deny"]

    static let categories: Set<UNNotificationCategory> = {
        let open = UNNotificationAction(identifier: Notifications.open, title: "Open", options: [.foreground])
        let publish = UNNotificationAction(identifier: Notifications.publish, title: "Publish", options: [.authenticationRequired, .foreground])
        let approve = UNNotificationAction(identifier: Notifications.publish, title: "Publish with Face ID", options: [.authenticationRequired, .foreground])
        // Allow and Always allow let a command run: unlocked, then Oby comes forward for Face ID
        // (`answer` below), which can't come up in the background. Deny goes from the Lock Screen.
        let allow = UNNotificationAction(identifier: "Allow", title: "Allow", options: [.authenticationRequired, .foreground])
        let always = UNNotificationAction(identifier: "Always allow", title: "Always allow", options: [.authenticationRequired, .foreground])
        let deny = UNNotificationAction(identifier: "Deny", title: "Deny", options: [.destructive])
        return [
            UNNotificationCategory(identifier: "ready", actions: [publish, open], intentIdentifiers: []),
            UNNotificationCategory(identifier: "job", actions: [open], intentIdentifiers: []),
            UNNotificationCategory(identifier: Notifications.approve, actions: [approve], intentIdentifiers: []),
            UNNotificationCategory(identifier: "permission", actions: [allow, deny, open], intentIdentifiers: []),
            UNNotificationCategory(identifier: "permissionRule", actions: [allow, always, deny, open], intentIdentifiers: []),
        ]
    }()

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories(Self.categories)
        // The watch's line to the runner goes through this phone, even while Oby is in the background.
        WatchRelay.shared.start(phone)
        return true
    }

    /// Every connection to a runner asks for the device token again: the relay hears of a new one,
    /// and the runner (maybe another Mac) gets what it pushes with. The first one, or the first
    /// job dispatched from the phone, asks whether Oby may notify; after that it doesn't ask again.
    static func ask() {
        Task {
            let center = UNUserNotificationCenter.current()
            switch await center.notificationSettings().authorizationStatus {
            case .authorized: UIApplication.shared.registerForRemoteNotifications()
            case .notDetermined:
                do {
                    if try await center.requestAuthorization(options: [.alert, .sound]) {
                        UIApplication.shared.registerForRemoteNotifications()
                    }
                } catch {
                    Logger.phone.error("asking to notify failed: \(error.localizedDescription, privacy: .public)")
                }
            default: break
            }
        }
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let runner = phone.runner
        Task {
            do {
                _ = try await runner.registerNotifications(try await PushRelay.register(deviceToken))
            } catch {
                Logger.phone.error("handing the runner its push keys failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: any Error) {
        Logger.phone.error("registering for notifications failed: \(error.localizedDescription, privacy: .public)")
    }

    /// The runner's clearing push: the job needs nothing any more (published, or running again).
    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any]) async -> UIBackgroundFetchResult {
        guard let id = userInfo["clear"] as? String else { return .noData }
        await Self.clear([id])
        return .newData
    }

    /// Takes these jobs' alerts out of Notification Center.
    static func clear(_ ids: Set<String>) async {
        guard !ids.isEmpty else { return }
        let center = UNUserNotificationCenter.current()
        let gone = await center.deliveredNotifications()
            .filter { ($0.request.content.userInfo["job"] as? String).map(ids.contains) ?? false }
            .map(\.request.identifier)
        if !gone.isEmpty { center.removeDeliveredNotifications(withIdentifiers: gone) }
    }

    /// A tap opens the job, or the conversation; Publish opens the job and starts publishing; a
    /// permission's action answers it.
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let content = response.notification.request.content
        if let item = Self.item(answering: response.actionIdentifier, content.userInfo) {
            await answer(item, response.actionIdentifier, content.userInfo)
        } else if let id = content.userInfo["job"] as? String {
            phone.open(id, publish: response.actionIdentifier == Self.publish)
        } else if let id = content.userInfo["conversation"] as? String {
            phone.open(conversation: id)
        }
    }

    /// The inbox item a permission's action answers: always the one the alert showed (its `item`,
    /// `<job>-permission-<id>`), never whatever waits by now; obid answers 409 when it's answered.
    nonisolated static func item(answering action: String, _ info: [AnyHashable: Any]) -> String? {
        answers.contains(action) ? info["item"] as? String : nil
    }

    /// Allow and Always allow open the job and ask for Face ID: unlocking the phone isn't enough.
    /// What Face ID approves is what the Mac says waits, not the push's words (anyone can seal to
    /// this iPhone's public key). A failed answer lets nothing run and says to open Oby.
    private func answer(_ item: String, _ answer: String, _ info: [AnyHashable: Any]) async {
        do {
            if answer != "Deny" {
                if let job = info["job"] as? String { phone.open(job, publish: false) }
                else if let id = info["conversation"] as? String { phone.open(conversation: id) }
                guard let waits = try await phone.runner.inbox().first(where: { $0.id == item && $0.isOpen }) else {
                    throw RunnerError(message: "It asks something else now.", status: 409)
                }
                guard await Self.ownerApproves(waits.title) else { return }
            }
            try await phone.answer(alert: item, answer)
        } catch {
            Logger.phone.error("answering inbox item \(item, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            try? await UNUserNotificationCenter.current().add(Self.couldntAnswer(info))
        }
    }

    private static func ownerApproves(_ reason: String) async -> Bool {
        // Face ID comes up only with Oby in front.
        if UIApplication.shared.applicationState != .active {
            for await _ in NotificationCenter.default.notifications(named: UIApplication.didBecomeActiveNotification) { break }
        }
        return (try? await LAContext().evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) ?? false
    }

    /// The alert a failed answer leaves (it was answered elsewhere, or the Mac is out of reach). It's
    /// a job's alert, so Open goes to the job (or the conversation) the permission was in.
    nonisolated static func couldntAnswer(_ info: [AnyHashable: Any]) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = "Oby"
        content.body = "Couldn't answer. Open Oby to see what it asks now."
        content.categoryIdentifier = "job"
        content.userInfo = info.filter { ["job", "conversation"].contains($0.key as? String) }
        return UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
    }

    /// With Oby open, the alert still shows, so it isn't missed.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}

/// Deskree's push relay (cloud/control-plane, `/v1/push/devices`): Apple's push key is Deskree's,
/// so the relay keeps this iPhone's APNs token and forwards obid's sealed alerts to it, never
/// reading them. obid gets the relay's `pushId`, a `pushKey` made from the `pushSecret`, and the
/// sealing key's public half; never the token or the `pushSecret`, which only re-registers and
/// unregisters this iPhone.
enum PushRelay {
    /// What obid gets (`POST /v1/notifications`, `apns`).
    struct HandOver: Codable, Equatable {
        var pushId: String
        /// What obid signs its pushes to the relay with (`pushKey(_:)`).
        var pushKey: String
        /// The X25519 public key obid seals to, raw, base64url.
        var sealKey: String
        var relay: String
    }

    /// The relay's registration, in the app's own Keychain group: the extension can't read it.
    private struct Registration: Codable {
        var pushId: String
        var pushSecret: String
        var apns: String
    }

    private static let account = "relay"
    private static var saved: Registration? {
        SealedPush.Keychain.read(account, group: nil).flatMap { try? JSONDecoder().decode(Registration.self, from: $0) }
    }
    private static var url: URL? { (Bundle.main.object(forInfoDictionaryKey: "ObyControlPlaneURL") as? String).flatMap(URL.init(string:)) }

    /// A build from Xcode gets Apple's development push service; TestFlight and the App Store the production one.
    #if DEBUG
    private static let sandbox = true
    #else
    private static let sandbox = false
    #endif

    /// Registers the token, or a new one in place of the old (with the old `pushId` and
    /// `pushSecret`), and answers what obid needs.
    static func register(_ token: Data) async throws -> HandOver {
        guard let url else { throw RunnerError(message: "This build has no push relay.") }
        let apns = token.map { String(format: "%02x", $0) }.joined()
        var registration = saved
        if registration?.apns != apns {
            let new = try await post(apns, replacing: registration, to: url)
            try SealedPush.Keychain.save(try JSONEncoder().encode(new), as: account, group: nil)
            registration = new
        }
        guard let registration else { throw RunnerError(message: "The push relay registered nothing.") }
        return HandOver(pushId: registration.pushId, pushKey: try pushKey(registration.pushSecret),
                        sealKey: try SealedPush.publicKey(), relay: url.absoluteString)
    }

    /// base64url(HMAC-SHA256 of "oby push key v1" under the `pushSecret`'s 32 bytes).
    nonisolated static func pushKey(_ pushSecret: String) throws -> String {
        guard let secret = Data(base64url: pushSecret) else { throw RunnerError(message: "The push relay's pushSecret isn't base64url.") }
        return Data(HMAC<SHA256>.authenticationCode(for: Data("oby push key v1".utf8), using: SymmetricKey(data: secret))).base64url
    }

    private static func post(_ apns: String, replacing old: Registration?, to relay: URL) async throws -> Registration {
        struct Body: Encodable { var apns: String; var topic: String; var sandbox: Bool; var pushId: String?; var pushSecret: String? }
        struct Answer: Decodable { var pushId: String; var pushSecret: String }
        var request = URLRequest(url: relay.appending(path: "v1/push/devices"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(Body(apns: apns, topic: Bundle.main.bundleIdentifier ?? "", sandbox: sandbox,
                                                         pushId: old?.pushId, pushSecret: old?.pushSecret))
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        // The relay no longer knows the old one: a new registration. A 422 is a token Apple refused.
        if old != nil, [401, 403, 404].contains(status) { return try await post(apns, replacing: nil, to: relay) }
        guard (200..<300).contains(status) else { throw RunnerError(message: "The push relay answered \(status).", status: status) }
        let answer = try JSONDecoder().decode(Answer.self, from: data)
        return Registration(pushId: answer.pushId, pushSecret: answer.pushSecret, apns: apns)
    }

    /// Unpairing, or pairing another Mac: the relay drops this iPhone's token, and the pushSecret
    /// and the sealing key go, so what the last Mac kept reaches nothing. The next connection makes new ones.
    static func forget() {
        SealedPush.forgetKey()
        guard let registration = saved, let url else { return }
        SealedPush.Keychain.remove(account, group: nil)
        var request = URLRequest(url: url.appending(path: "v1/push/devices/\(registration.pushId)"))
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(registration.pushSecret)", forHTTPHeaderField: "Authorization")
        Task {
            do { _ = try await URLSession.shared.data(for: request) } catch {
                Logger.phone.error("the push relay didn't hear of the unpairing: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
