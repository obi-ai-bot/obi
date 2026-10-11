import UserNotifications
import WatchKit

/// The alerts the runner sends the phone (docs/runner-api.md), mirrored here. The watch registers
/// the same categories, so a mirrored "ready" alert offers Publish and Open, and "job" offers
/// Open. Tapping one opens the job; Publish opens it and asks for the crown.
final class WatchNotifications: NSObject, WKApplicationDelegate, UNUserNotificationCenterDelegate {
    let watch = Watch()

    static let publish = "publish"
    static let open = "open"

    func applicationDidFinishLaunching() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let open = UNNotificationAction(identifier: Self.open, title: "Open", options: [.foreground])
        let publish = UNNotificationAction(identifier: Self.publish, title: "Publish", options: [.foreground])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: "ready", actions: [publish, open], intentIdentifiers: []),
            UNNotificationCategory(identifier: "job", actions: [open], intentIdentifiers: []),
        ])
    }

    /// The phone's job list can wake the app in the background: it lands in `watch`, which updates
    /// the complications.
    func handle(_ backgroundTasks: Set<WKRefreshBackgroundTask>) {
        for task in backgroundTasks {
            if let delivery = task as? WKWatchConnectivityRefreshBackgroundTask {
                watch.finishWhenDelivered(delivery)
            } else {
                task.setTaskCompletedWithSnapshot(false)
            }
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let id = response.notification.request.content.userInfo["job"] as? String else { return }
        watch.open(id, publish: response.actionIdentifier == Self.publish)
    }

    /// With Oby open on the wrist, the alert still shows, so it isn't missed.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}
