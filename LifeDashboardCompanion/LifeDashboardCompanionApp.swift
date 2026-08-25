import SwiftUI
import HealthKit

@main
struct LifeDashboardCompanionApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    /// Timestamp of last foreground catch-up sync (throttle to max 1x per 5 min)
    @State private var lastForegroundSync: Date = .distantPast

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }

            let prefs = PreferencesManager.shared
            guard !prefs.healthWebhookUrls.isEmpty,
                  !prefs.healthEnabledDataTypes.isEmpty else { return }

            // Throttle: max once every 5 minutes
            guard Date().timeIntervalSince(lastForegroundSync) > 300 else { return }
            lastForegroundSync = Date()

            Task {
                // Drain pending queue first
                await HealthSyncManager.shared.drainPendingQueue()

                // Incremental sync catches anything background delivery missed
                let enabledTypes = prefs.healthEnabledDataTypes
                _ = await HealthSyncManager.shared.performIncrementalSync(types: enabledTypes)
            }
        }
    }
}

class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Register background tasks
        BackgroundSyncManager.shared.registerBackgroundTasks()

        let prefs = PreferencesManager.shared

        if !prefs.healthWebhookUrls.isEmpty && !prefs.healthEnabledDataTypes.isEmpty {
            // Set up HKObserverQuery-based background sync (primary mechanism)
            BackgroundSyncManager.shared.setupHealthKitObservers()

            // Schedule BGProcessingTask as fallback/catch-up (idle + charging)
            BackgroundSyncManager.shared.scheduleHealthSync()

            // Schedule BGAppRefreshTask - runs more frequently, no charging needed
            BackgroundSyncManager.shared.scheduleHealthRefresh()
        }

        // Start network monitoring - drains pending queue when connectivity returns
        _ = NetworkMonitor.shared

        // Quiet notification authorization for sync-failure alerts (no prompt)
        SyncFailureNotifier.shared.requestProvisionalAuthorization()

        // Drain any pending sync items from previous session
        Task {
            await HealthSyncManager.shared.drainPendingQueue()
        }

        return true
    }
}
