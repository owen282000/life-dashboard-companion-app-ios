import Foundation
import UserNotifications
import OSLog

/// Posts a local notification when syncs keep failing, so silent background
/// problems surface without the user having to open the app or check the widget.
final class SyncFailureNotifier: Sendable {
    static let shared = SyncFailureNotifier()

    private static let streakKey = "sync_failure_streak"
    private static let notificationId = "sync-failure"

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
        content.body = String(
            localized: "\(streak) syncs in a row failed. Payloads are queued and will retry. Check the Logs tab for details."
        )
        if let lastError = lastError {
            content.body += " " + String(localized: "Last error: \(lastError)")
        }
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
}
