import Foundation
import UserNotifications

/// Opens a sealed alert before it shows (SealedPush.swift). The relay's payload says only "Open Oby
/// to see it."; that stays when the alert can't be opened (no key yet, or another key).
final class NotificationService: UNNotificationServiceExtension {
    /// The alerts already shown, in this extension's own defaults: nothing else opens alerts.
    private static let lock = NSLock()

    override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        let content = request.content
        guard let sealed = content.userInfo["sealed"] as? String, let key = SealedPush.savedKey(),
              let alert = try? SealedPush.open(sealed, with: key),
              let opened = content.mutableCopy() as? UNMutableNotificationContent else { return contentHandler(content) }
        guard Self.lock.withLock({ Self.news(alert) }) else {
            // A replay: shown already, or sealed over a day ago. Dropping it outright takes Apple's
            // filtering entitlement, so it keeps the generic text, without a sound or lighting the screen.
            opened.sound = nil
            opened.interruptionLevel = .passive
            return contentHandler(opened)
        }
        SealedPush.show(alert, in: opened)
        contentHandler(opened)
    }

    private static func news(_ alert: SealedPush.Alert) -> Bool {
        var seen = UserDefaults.standard.dictionary(forKey: "seen") as? [String: TimeInterval] ?? [:]
        defer { UserDefaults.standard.set(seen, forKey: "seen") }
        return SealedPush.isNews(alert, seen: &seen)
    }
}
