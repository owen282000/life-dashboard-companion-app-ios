import Foundation
import UserNotifications
import OSLog

/// Posts a local notification when syncs keep failing, so silent background
/// problems surface without the user having to open the app or check the widget.
final class SyncFailureNotifier: Sendable {
    static let shared = SyncFailureNotifier()

    private static let streakKey = "sync_failure_streak"
    private static let notificationId = "sync-failure"
    private static let droppedKey = "sync_dropped_count"
    private static let droppedNotificationId = "sync-dropped"

    private let logger = Logger(subsystem: "com.owen282000.lifedashboard", category: "FailureNotifier")

    private init() {}

    /// Quiet, prompt-free authorization: provisional notifications go straight
    /// to Notification Center without interrupting the user.
    func requestProvisionalAuthorization() {
        guard PreferencesManager.shared.failureNotificationsEnabled else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .provisional]) { _, _ in }
    }

    /// Full authorization with the system prompt, used when the user explicitly
    /// enables failure notifications in the app.
    func requestFullAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// The failure notification's text. `lastError` is already in the phone's language.
    static func failureBody(streak: Int, lastError: String?) -> String {
        var body = String(
            localized: "\(streak) syncs in a row failed. Payloads are queued and will retry. Check the Logs tab for details."
        )
        if let lastError {
            body += " " + String(localized: "Last error: \(lastError)")
        }
        return body
    }

    func recordResult(success: Bool, lastError: String?) {
        let defaults = UserDefaults.standard

        guard !success else {
            if defaults.integer(forKey: SyncFailureNotifier.streakKey) > 0 {
                defaults.set(0, forKey: SyncFailureNotifier.streakKey)
                UNUserNotificationCenter.current()
                    .removeDeliveredNotifications(withIdentifiers: [SyncFailureNotifier.notificationId])
            }
            return
        }

        let streak = defaults.integer(forKey: SyncFailureNotifier.streakKey) + 1
        defaults.set(streak, forKey: SyncFailureNotifier.streakKey)

        let prefs = PreferencesManager.shared
        guard prefs.failureNotificationsEnabled else { return }

        let threshold = max(1, prefs.failureNotificationThreshold)
        guard streak % threshold == 0 else { return }

        let content = UNMutableNotificationContent()
        content.title = String(localized: "Webhook sync is failing")
        content.body = SyncFailureNotifier.failureBody(streak: streak, lastError: lastError)
        content.sound = nil

        let request = UNNotificationRequest(
            identifier: SyncFailureNotifier.notificationId,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { [logger] error in
            if let error = error {
                logger.error("Failed to schedule failure notification: \(error.localizedDescription)")
            }
        }
        logger.info("Posted sync failure notification (streak: \(streak))")
    }

    // MARK: - Dropped from the queue

    /// The retry queue dropped `count` payloads that waited a week, and their records with
    /// them. Lost data is worse than a failing sync, so this does not wait for the threshold
    /// or the failure notification switch, as on Android: it notifies at once, and counts up
    /// while the notification is still there. A delivery does not clear it, since the records
    /// stay lost.
    func notifyDropped(count: Int) {
        guard count > 0 else { return }
        let logger = self.logger
        // Quiet, prompt-free authorization, for a user who never switched on the failure
        // notifications; it changes nothing once the user decided.
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .provisional]) { _, _ in
            UNUserNotificationCenter.current().getDeliveredNotifications { delivered in
                let showing = delivered.contains { $0.request.identifier == SyncFailureNotifier.droppedNotificationId }
                let defaults = UserDefaults.standard
                let total = (showing ? defaults.integer(forKey: SyncFailureNotifier.droppedKey) : 0) + count
                defaults.set(total, forKey: SyncFailureNotifier.droppedKey)

                let content = UNMutableNotificationContent()
                content.title = String(localized: "Health data was lost")
                content.body = SyncFailureNotifier.droppedBody(count: total)
                content.sound = nil
                let request = UNNotificationRequest(
                    identifier: SyncFailureNotifier.droppedNotificationId, content: content, trigger: nil
                )
                UNUserNotificationCenter.current().add(request) { error in
                    if let error {
                        logger.error("Failed to post the dropped payloads notification: \(error.localizedDescription)")
                    }
                }
            }
        }
    }

    static func droppedBody(count: Int) -> String {
        String(localized: "\(count) undelivered syncs were dropped from the queue after a week, so their records are lost. Check the Logs tab for details.")
    }
}
