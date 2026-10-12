import Foundation
import UserNotifications

/// Every notification Kept can post, in one place.
///
/// Three processes reach for these: the engine at the end of a run, the
/// headless `--staleness-check`, and the preview buttons in Settings →
/// Advanced. The preview exists to show what a real notification looks like, so
/// it has to build the identical content — a copy of the strings would drift
/// the moment one of them was reworded.
///
/// The kind carries plain strings rather than a built `UNMutableNotificationContent`
/// so it can cross isolation boundaries; the content is assembled at the point
/// it is handed to the notification centre.
enum KeptNotification {
    enum Kind: Sendable {
        case backupFailed(message: String)
        case backupComplete(body: String)
        /// Finished, but some files couldn't be copied.
        case backupIncomplete(message: String)
        case stale(message: String)
    }

    static func content(_ kind: Kind) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        switch kind {
        case .backupFailed(let message):
            content.title = "Backup failed"
            content.body = message
            content.sound = UNNotificationSound(named: UNNotificationSoundName("Basso"))
        case .backupComplete(let body):
            content.title = "Backup complete"
            content.body = body
        case .backupIncomplete(let message):
            content.title = "Backup incomplete"
            content.body = message
            content.sound = UNNotificationSound(named: UNNotificationSoundName("Basso"))
        case .stale(let message):
            content.title = "Backups have stopped"
            content.body = message
            // The "Launch Kept" button; the category is registered by both the
            // running app and the headless check.
            content.categoryIdentifier = StalenessCheck.categoryIdentifier
            content.sound = UNNotificationSound(named: UNNotificationSoundName("Basso"))
        }
        return content
    }

    /// Fire-and-forget post. A no-op outside an app bundle — `swift run` and the
    /// test binaries have nothing for UserNotifications to attach to.
    static func post(_ kind: Kind) async {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        try? await UNUserNotificationCenter.current().add(
            UNNotificationRequest(
                identifier: UUID().uuidString, content: content(kind), trigger: nil))
    }
}
