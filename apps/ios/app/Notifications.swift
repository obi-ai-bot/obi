import OSLog
import UIKit
import UserNotifications

/// The alerts the runner sends when a job needs you (Runner/Push.swift): "Ready to publish" with
/// Publish and Open, a failed or interrupted job with Open. Tapping one opens the job; Publish
/// brings Oby forward, where Face ID signs it as it does in the app.
final class Notifications: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    let phone = Phone()

    static let publish = "publish"
    static let open = "open"
    /// A publish the watch asked for while Oby was in the background (apps/ios/app/WatchRelay.swift):
    /// Face ID can't come up then, so this notification's Publish does it.
    static let approve = "approve"

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let open = UNNotificationAction(identifier: Self.open, title: "Open", options: [.foreground])
        let publish = UNNotificationAction(identifier: Self.publish, title: "Publish", options: [.authenticationRequired, .foreground])
        // The runner's `category`: "ready" for a job waiting for Publish, "job" for the rest.
        let approve = UNNotificationAction(identifier: Self.publish, title: "Publish with Face ID", options: [.authenticationRequired, .foreground])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: "ready", actions: [publish, open], intentIdentifiers: []),
            UNNotificationCategory(identifier: "job", actions: [open], intentIdentifiers: []),
            UNNotificationCategory(identifier: Self.approve, actions: [approve], intentIdentifiers: []),
        ])
        // Allowed before: the token can change, so the runner gets it on every launch.
        Task {
            if await center.notificationSettings().authorizationStatus == .authorized { application.registerForRemoteNotifications() }
        }
        // The watch's line to the runner goes through this phone, even while Oby is in the background.
        WatchRelay.shared.start(phone)
        return true
    }

    /// The first connection to a runner, or the first job dispatched from the phone, asks whether
    /// Oby may notify; after that it doesn't ask again.
    static func ask() {
        Task {
            let center = UNUserNotificationCenter.current()
            guard await center.notificationSettings().authorizationStatus == .notDetermined else { return }
            do {
                if try await center.requestAuthorization(options: [.alert, .sound]) {
                    UIApplication.shared.registerForRemoteNotifications()
                }
            } catch {
                Logger.phone.error("asking to notify failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let runner = phone.runner
        Task {
            do {
                _ = try await runner.registerNotifications(token: deviceToken)
            } catch {
                Logger.phone.error("handing the runner the device token failed: \(error.localizedDescription, privacy: .public)")
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

    /// A tap opens the job; Publish opens it and starts publishing.
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let id = response.notification.request.content.userInfo["job"] as? String else { return }
        phone.open(id, publish: response.actionIdentifier == Self.publish)
    }

    /// With Oby open, the alert still shows, so it isn't missed.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}
