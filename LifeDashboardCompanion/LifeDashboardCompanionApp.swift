import SwiftUI
import HealthKit

@main
struct LifeDashboardCompanionApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                // The appearance chosen on About, set on the window, so the first-run setup,
                // every sheet and the system's own sheets follow it too.
                .background(WindowAppearance())
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }

            // Opening the app is one more chance for the scheduled sync, not a sync of its own:
            // outside quiet hours and when the schedule says it is due, it catches up what
            // background delivery missed. Sync Now is there for everything else.
            Task {
                _ = await SyncCoordinator.shared.runAutomatic(.foreground)
                BackgroundSyncManager.shared.replan()
                // A changed schedule or destination, or the failure notifications switched off,
                // moves or removes the reminder for a quiet app; a delivery just now set it already.
                SyncFailureNotifier.shared.scheduleQuietReminder(lastDelivered: SharedSyncStatus.read().lastDelivered)
            }
        }
    }
}

// MARK: - Appearance

extension AppTheme {
    /// What the window is overridden with; unspecified follows the system.
    var userInterfaceStyle: UIUserInterfaceStyle {
        switch self {
        case .system: return .unspecified
        case .light: return .light
        case .dark: return .dark
        }
    }
}

/// Sets the chosen appearance on the window itself rather than through preferredColorScheme,
/// which does not reliably go back to the system's appearance once it has set one. It is set
/// as the view joins the window, before the first frame, so a dark choice never flashes light.
private struct WindowAppearance: UIViewRepresentable {
    @ObservedObject private var prefs = PreferencesManager.shared

    func makeUIView(context: Context) -> WindowStyleView {
        let view = WindowStyleView()
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: WindowStyleView, context: Context) {
        view.style = prefs.appTheme.userInterfaceStyle
    }
}

private final class WindowStyleView: UIView {
    var style = UIUserInterfaceStyle.unspecified {
        didSet { apply() }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        apply()
    }

    private func apply() {
        guard let window, window.overrideUserInterfaceStyle != style else { return }
        window.overrideUserInterfaceStyle = style
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
