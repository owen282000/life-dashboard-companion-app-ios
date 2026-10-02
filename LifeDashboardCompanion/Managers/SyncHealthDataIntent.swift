import AppIntents
#if !WIDGET_EXTENSION
import os
import UIKit
#endif

/// Exposes "Sync Health Data" to the Shortcuts app and Siri, so syncs can be
/// automated (time of day, arriving home, charger connected) or triggered by voice. The home
/// screen widget's button and the Control Center control run it too.
///
/// Compiled into the widget extension as well, which needs the type for its buttons. It is a
/// LiveActivityIntent only for where it runs: iOS performs such an intent in the app's process,
/// launching the app in the background when it is not running, where a widget's intent would
/// otherwise run in the extension, which cannot read HealthKit or reach SyncCoordinator.
struct SyncHealthDataIntent: AppIntent, LiveActivityIntent {
    static let title: LocalizedStringResource = "Sync Health Data"
    static let description = IntentDescription(
        "Reads your enabled Apple Health data types and delivers them to your webhooks and MQTT broker."
    )

    #if WIDGET_EXTENSION
    func perform() async throws -> some IntentResult & ProvidesDialog {
        // Not reached: see above. Said plainly in case iOS ever runs it here.
        .result(dialog: "Open Life Dashboard to sync.")
    }
    #else
    /// At most one accepted run a minute, like the Android app's sync broadcast.
    static let rateLimit = SyncTriggerRateLimit()

    /// Runs at the time a Shortcuts automation sets, which may well be while the iPhone is
    /// locked; Health data is unreadable then, and the answer says so. Otherwise it sends what
    /// is queued and the records since the last sync, like a scheduled sync but without asking
    /// the schedule, as Sync Now does not either. The new records go to MQTT too, and with only
    /// a broker set up, to MQTT alone.
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let unlocked = await MainActor.run { UIApplication.shared.isProtectedDataAvailable }
        guard unlocked else {
            return .result(dialog: "Your iPhone is locked, so Health data can't be read. The next sync catches up.")
        }
        // A widget button tapped five times would otherwise queue five syncs behind each other.
        guard Self.rateLimit.tryAccept() else {
            return .result(dialog: "A sync started less than a minute ago. Try again in a minute.")
        }
        let result = await SyncCoordinator.shared.runManual(full: false)
        switch result {
        case .success(let syncCounts, _):
            let total = syncCounts.values.reduce(0, +)
            return .result(dialog: "Synced \(total) health records.")
        case .noData:
            return .result(dialog: "No new health data to sync.")
        case .failure(let error):
            return .result(dialog: "Sync failed: \(AppDiagnostic.display(error))")
        }
    }
    #endif
}

#if !WIDGET_EXTENSION
/// Android's rate limit on its sync broadcast: a trigger within a minute of the last accepted
/// one is ignored, so a flood of taps or automations becomes at most one sync a minute. In
/// memory only, as there: a process that was gone has seen no flood to hold back.
struct SyncTriggerRateLimit: Sendable {
    static let minimumGap: Duration = .seconds(60)

    private let lastAccepted = OSAllocatedUnfairLock<ContinuousClock.Instant?>(initialState: nil)

    static func allows(now: ContinuousClock.Instant, lastAcceptedAt: ContinuousClock.Instant?) -> Bool {
        guard let lastAcceptedAt else { return true }
        return now - lastAcceptedAt >= minimumGap
    }

    /// True, and remembered, when a trigger at `now` may sync.
    func tryAccept(now: ContinuousClock.Instant = .now) -> Bool {
        lastAccepted.withLock { last in
            guard Self.allows(now: now, lastAcceptedAt: last) else { return false }
            last = now
            return true
        }
    }
}

struct LifeDashboardAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SyncHealthDataIntent(),
            phrases: [
                "Sync my health data with \(.applicationName)",
                "Sync \(.applicationName)"
            ],
            shortTitle: "Sync Health Data",
            systemImageName: "arrow.triangle.2.circlepath"
        )
    }
}
#endif
