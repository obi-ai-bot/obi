import UserNotifications

/// Opens a sealed alert before it shows (SealedPush.swift). The relay's payload says only "Open Oby
/// to see it."; that stays when the alert can't be opened (no key yet, or another key).
final class NotificationService: UNNotificationServiceExtension {
    override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        let content = request.content
        guard let sealed = content.userInfo["sealed"] as? String, let key = SealedPush.savedKey(),
              let alert = try? SealedPush.open(sealed, with: key),
              let opened = content.mutableCopy() as? UNMutableNotificationContent else { return contentHandler(content) }
        SealedPush.show(alert, in: opened)
        contentHandler(opened)
    }
}
