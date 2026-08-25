import AppIntents

/// Exposes "Sync Health Data" to the Shortcuts app and Siri, so syncs can be
/// automated (time of day, arriving home, charger connected) or triggered by voice.
struct SyncHealthDataIntent: AppIntent {
    static let title: LocalizedStringResource = "Sync Health Data"
    static let description = IntentDescription(
        "Reads your enabled Apple Health data types and delivers them to your configured webhooks."
    )

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let result = await HealthSyncManager.shared.performSync()
        switch result {
        case .success(let syncCounts):
            let total = syncCounts.values.reduce(0, +)
            return .result(dialog: "Synced \(total) health records to your webhook.")
        case .noData:
            return .result(dialog: "No new health data to sync.")
        case .failure(let error):
            return .result(dialog: "Sync failed: \(error)")
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
