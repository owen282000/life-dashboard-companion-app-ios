import AppIntents
import UIKit

/// Exposes "Sync Health Data" to the Shortcuts app and Siri, so syncs can be
/// automated (time of day, arriving home, charger connected) or triggered by voice.
struct SyncHealthDataIntent: AppIntent {
    static let title: LocalizedStringResource = "Sync Health Data"
    static let description = IntentDescription(
        "Reads your enabled Apple Health data types and delivers them to your webhooks and MQTT broker."
    )

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
        let result = await SyncCoordinator.shared.runManual(full: false)
        switch result {
        case .success(let syncCounts):
            let total = syncCounts.values.reduce(0, +)
            return .result(dialog: "Synced \(total) health records.")
        case .noData:
            return .result(dialog: "No new health data to sync.")
        case .failure(let error):
            return .result(dialog: "Sync failed: \(AppDiagnostic.display(error))")
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
