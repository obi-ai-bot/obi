import Foundation
import UserNotifications

/// Opens a sealed alert before it shows (SealedPush.swift, `shown`).
final class NotificationService: UNNotificationServiceExtension {
    /// Guards the alerts already shown, kept in this extension's own defaults: nothing else opens alerts.
    private static let lock = NSLock()

    override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        contentHandler(Self.lock.withLock {
            var seen = UserDefaults.standard.dictionary(forKey: "seen") as? [String: TimeInterval] ?? [:]
            defer { UserDefaults.standard.set(seen, forKey: "seen") }
            return SealedPush.shown(request.content, key: SealedPush.savedKey(), seen: &seen)
        })
    }
}
