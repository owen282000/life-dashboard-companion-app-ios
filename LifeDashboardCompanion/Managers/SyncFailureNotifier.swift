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
    private static let partialStreakKey = "sync_partial_streak"
    private static let partialNotificationId = "sync-partial"

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

    // MARK: - Partial delivery

    /// The partial streak, next to the failure streak: deliveries in a row that one webhook took
    /// and another missed. Such a delivery counts as done, so nothing is queued for the one that
    /// missed it, and the failure streak never sees it. iOS syncs one category, Apple Health, so
    /// there is one streak, as Android keeps one per category.
    enum PartialStreak {
        /// The streak after one delivery. A delivery that missed some webhooks counts up, one
        /// that reached every webhook ends it, and a failure leaves it alone: the failure streak
        /// covers that.
        static func next(_ streak: Int, delivered: Bool, missedUrls: [String]) -> Int {
            guard delivered else { return streak }
            return missedUrls.isEmpty ? 0 : streak + 1
        }

        /// At the failure threshold and every multiple of it, like the failure notification.
        static func notifies(_ streak: Int, threshold: Int, enabled: Bool) -> Bool {
            enabled && streak > 0 && streak % max(1, threshold) == 0
        }
    }

    static func partialTitle() -> String {
        let category = String(localized: "Apple Health")
        return String(localized: "Not every destination gets your \(category) data")
    }

    /// `count` deliveries in a row missed the webhooks at `hosts`, named by host alone.
    static func partialBody(count: Int, hosts: String) -> String {
        String(localized: "\(hosts) missed the last \(count) syncs. Another destination took them, so they are not queued for \(hosts). See the Logs tab.")
    }

    /// Records which webhooks one delivery reached (see `PartialStreak`), and notifies at the
    /// failure threshold, naming the webhooks this delivery missed by their host.
    func recordReach(delivered: Bool, missedUrls: [String]) {
        let defaults = UserDefaults.standard
        let before = defaults.integer(forKey: SyncFailureNotifier.partialStreakKey)
        let streak = PartialStreak.next(before, delivered: delivered, missedUrls: missedUrls)
        guard streak != before else { return }
        defaults.set(streak, forKey: SyncFailureNotifier.partialStreakKey)
        guard streak > 0 else {
            UNUserNotificationCenter.current()
                .removeDeliveredNotifications(withIdentifiers: [SyncFailureNotifier.partialNotificationId])
            return
        }

        let prefs = PreferencesManager.shared
        guard PartialStreak.notifies(
            streak, threshold: prefs.failureNotificationThreshold, enabled: prefs.failureNotificationsEnabled
        ) else { return }

        let content = UNMutableNotificationContent()
        content.title = SyncFailureNotifier.partialTitle()
        content.body = SyncFailureNotifier.partialBody(count: streak, hosts: WebhookHosts.list(missedUrls))
        content.sound = nil
        let request = UNNotificationRequest(
            identifier: SyncFailureNotifier.partialNotificationId, content: content, trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { [logger] error in
            if let error {
                logger.error("Failed to schedule partial delivery notification: \(error.localizedDescription)")
            }
        }
        logger.info("Posted partial delivery notification (streak: \(streak))")
    }

    // MARK: - Dropped from the queue

    /// The retry queue dropped `count` payloads, after a week of failures or because it was
    /// full, and their records with them. Lost data is worse than a failing sync, so this does
    /// not wait for the threshold or the failure notification switch, as on Android: it
    /// notifies at once, and counts up while the notification is still there. A delivery does
    /// not clear it, since the records stay lost.
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
        String(localized: "\(count) undelivered syncs were dropped from the queue, so their records are lost. Check the Logs tab for details.")
    }

    // MARK: - Too quiet

    private static let quietNotificationId = "sync-quiet"

    /// A reminder for the moment the next delivery is overdue (`SyncHealthCheck`), set after
    /// every delivery and replaced by the next one. It is scheduled ahead, because an app that
    /// iOS no longer wakes in the background cannot post anything at that moment itself.
    /// Without a delivery yet, without a destination, with a schedule that never runs or with
    /// the failure notifications off, there is none.
    func scheduleQuietReminder(lastDelivered: Date?) {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [SyncFailureNotifier.quietNotificationId])
        center.removeDeliveredNotifications(withIdentifiers: [SyncFailureNotifier.quietNotificationId])
        let prefs = PreferencesManager.shared
        guard prefs.failureNotificationsEnabled, let lastDelivered,
              let due = SyncHealthCheck.overdueDate(
                lastDelivered: lastDelivered, schedule: prefs.healthSyncSchedule,
                hasDestination: prefs.healthSyncConfigured, timeZone: .current
              ) else { return }

        let content = UNMutableNotificationContent()
        content.title = String(localized: "No sync in a while")
        content.body = SyncFailureNotifier.quietBody(since: lastDelivered)
        content.sound = nil
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(60, due.timeIntervalSinceNow), repeats: false)
        let request = UNNotificationRequest(identifier: SyncFailureNotifier.quietNotificationId, content: content, trigger: trigger)
        center.add(request) { [logger] error in
            if let error {
                logger.error("Failed to schedule the quiet reminder: \(error.localizedDescription)")
            }
        }
    }

    static func quietBody(since: Date) -> String {
        let day = since.formatted(date: .abbreviated, time: .omitted)
        return String(localized: "Nothing was delivered since \(day). iOS may be holding the app back: open it to sync, and check Background App Refresh and Low Power Mode.")
    }
}

/// When background syncs are too quiet (P2-27). iOS gives no app a battery exemption, so a sync
/// that stops does so silently: Background App Refresh off holds every background sync until the
/// app is opened, and Low Power Mode pauses them while it is on. Pure, so it is unit tested; the
/// Health screen and the reminder above read it.
enum SyncHealthCheck {
    /// At least two days, so a phone left at home over a weekend does not count.
    static let minimumQuiet: TimeInterval = 2 * 24 * 3600
    /// A day past the next sync the schedule expects, for a schedule that runs less than daily.
    static let grace: TimeInterval = 24 * 3600

    /// When a delivery at `lastDelivered` counts as overdue: the later of two days on and a day
    /// past the next scheduled sync. Nil when no automatic sync is expected at all.
    static func overdueDate(lastDelivered: Date, schedule: SyncSchedule, hasDestination: Bool, timeZone: TimeZone) -> Date? {
        guard hasDestination, !schedule.isNeverRunning,
              let next = schedule.nextRunDate(now: lastDelivered, lastRun: lastDelivered, timeZone: timeZone) else {
            return nil
        }
        return max(lastDelivered.addingTimeInterval(minimumQuiet), next.addingTimeInterval(grace))
    }

    static func isOverdue(lastDelivered: Date?, now: Date, schedule: SyncSchedule, hasDestination: Bool, timeZone: TimeZone) -> Bool {
        guard let lastDelivered,
              let due = overdueDate(lastDelivered: lastDelivered, schedule: schedule, hasDestination: hasDestination, timeZone: timeZone) else {
            return false
        }
        return now >= due
    }

    /// What most likely holds the syncs, for the line on the Health screen.
    enum Cause: Equatable {
        case refreshOff, lowPower, unknown
    }

    static func cause(refreshOff: Bool, lowPower: Bool) -> Cause {
        refreshOff ? .refreshOff : lowPower ? .lowPower : .unknown
    }
}

/// When to ask for an App Store rating (P1-28, P1-43), the same rule as the Android app.
///
/// The app is set up once and then syncs in the background, so the few times it is on screen
/// have to count. A moment is good only after something went right, never next to an error:
///
/// - `backfillDone`: a backfill the user started has just delivered their history, with nothing
///   failing or queued. It counts from the first day, because for many people the setup is the
///   last time they look at the app.
/// - `opened` and `syncDelivered`: the app is in front, or a sync from the screen delivered,
///   after at least a day of use, with a delivery to every address within the last day and no
///   failed delivery in that day. Someone who came in to fix a problem is asked on a later
///   visit, not in the same one.
///
/// Apple shows the prompt at most three times a year, never in TestFlight, and does not say
/// whether it appeared (see `wasShown`). So a request that probably went unseen is tried again
/// after two weeks, one that was seen only after four months, and never more than three times
/// in all. Only Apple's own prompt asks: guideline 5.6.1 allows no prompt of our own, so there
/// is no card for it, only Rate the app under About. Pure, so it is unit tested; the Health
/// screen asks it.
enum ReviewPrompt {
    static let firstUseKey = "review_first_use"
    static let lastRequestKey = "review_last_request"
    static let lastShownKey = "review_last_shown"
    static let shownCountKey = "review_shown_count"
    /// Until 1.11.1 the question came once per version; the pauses below took its place.
    static let askedVersionKey = "review_asked_version"

    private static let day: TimeInterval = 24 * 3600
    /// A day, so the app has synced on its own at least once before the first question.
    static let minimumUse: TimeInterval = day
    /// A delivery this recent counts as the moment when the app comes to the foreground.
    static let recentDelivery: TimeInterval = day
    /// A failed delivery this recent means the visit may be about that failure.
    static let quiet: TimeInterval = day
    /// How long the screen stays as it is before the question comes, so it never meets someone
    /// at the door: Apple asks not to prompt right at launch.
    static let rest: TimeInterval = 2.5
    /// After a prompt that was seen: the three times a year Apple allows.
    static let pauseAfterShown: TimeInterval = 120 * day
    /// After a request that Apple probably kept to itself.
    static let retryAfterUnseen: TimeInterval = 14 * day
    /// Whoever closed the prompt three times has answered.
    static let maximumShown = 3
    /// How long after a request the app looks for the prompt.
    static let watch: TimeInterval = 2

    enum Moment: CaseIterable {
        case opened, syncDelivered, backfillDone
    }

    /// A backfill finishes on its own page, so the Health tab hears of it when it is in front
    /// again: within this long that still counts as the backfill's moment.
    static let backfillFresh: TimeInterval = 3600

    /// What the Health tab coming to the front counts as.
    static func momentOnOpening(backfillFinished: Date?, now: Date) -> Moment {
        guard let backfillFinished, now.timeIntervalSince(backfillFinished) <= backfillFresh else { return .opened }
        return .backfillDone
    }

    struct State: Equatable {
        /// When the Health tab first showed after the setup.
        var firstUse: Date?
        var lastDelivered: Date?
        var lastSyncSucceeded: Bool
        var failureStreak: Int
        var partialStreak: Int
        var pending: Int
        /// The newest failed delivery still in the log.
        var lastFailure: Date?
    }

    /// What was asked before.
    struct History: Equatable {
        /// When Apple was last asked for its prompt.
        var lastRequest: Date?
        /// Whether that request probably showed it.
        var lastRequestShown = false
        /// How many requests probably showed it.
        var shownCount = 0
    }

    /// Nothing is failing, queued or missing an address.
    private static func isHealthy(_ state: State) -> Bool {
        state.lastSyncSucceeded && state.failureStreak == 0 && state.partialStreak == 0 && state.pending == 0
    }

    /// Whether `moment` is one to ask at, going by the sync side alone.
    static func isGoodMoment(_ moment: Moment, _ state: State, now: Date) -> Bool {
        guard isHealthy(state) else { return false }
        if moment == .backfillDone { return true }
        guard let firstUse = state.firstUse, now.timeIntervalSince(firstUse) >= minimumUse else { return false }
        guard let delivered = state.lastDelivered, now.timeIntervalSince(delivered) <= recentDelivery else { return false }
        guard let failure = state.lastFailure else { return true }
        return now.timeIntervalSince(failure) >= quiet
    }

    /// Whether enough time has passed since the last request, and the prompt was not seen too often.
    static func mayRequest(_ history: History, now: Date) -> Bool {
        guard history.shownCount < maximumShown else { return false }
        guard let last = history.lastRequest else { return true }
        return now.timeIntervalSince(last) >= (history.lastRequestShown ? pauseAfterShown : retryAfterUnseen)
    }

    static func shouldAsk(_ moment: Moment, _ state: State, _ history: History, now: Date) -> Bool {
        isGoodMoment(moment, state, now: now) && mayRequest(history, now: now)
    }

    /// Whether the prompt was probably on screen. Apple does not say; its prompt comes in a
    /// window of its own, and takes the app out of the active state while it is up. Wrong
    /// either way costs little: a seen prompt taken for unseen is asked for again after two
    /// weeks, and then Apple's own limit decides.
    static func wasShown(windowAppeared: Bool, leftActive: Bool) -> Bool {
        windowAppeared || leftActive
    }
}
