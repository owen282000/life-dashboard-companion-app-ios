import SwiftUI
import HealthKit

@main
struct LifeDashboardCompanionApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }

            // Opening the app is one more chance for the scheduled sync, not a sync of its own:
            // outside quiet hours and when the schedule says it is due, it catches up what
            // background delivery missed. Sync Now is there for everything else.
            Task {
                _ = await SyncCoordinator.shared.runAutomatic(.foreground)
                BackgroundSyncManager.shared.replan()
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

        if PreferencesManager.shared.healthSyncConfigured {
            // HKObserverQuery-based background sync (the primary mechanism), and both background
            // tasks aimed at the next moment the schedule allows a sync
            BackgroundSyncManager.shared.start()
        }
        BackgroundSyncManager.shared.startObservingScheduleChanges()

        // Loads an unfinished backfill and picks it up when the app becomes active
        _ = BackfillController.shared

        // Start network monitoring - drains pending queue when connectivity returns
        _ = NetworkMonitor.shared

        // Quiet notification authorization for sync-failure alerts (no prompt)
        SyncFailureNotifier.shared.requestProvisionalAuthorization()

        // Retry what the previous session queued, unless it is quiet hours
        Task {
            await SyncCoordinator.shared.drain(automatic: true)
        }

        return true
    }
}
