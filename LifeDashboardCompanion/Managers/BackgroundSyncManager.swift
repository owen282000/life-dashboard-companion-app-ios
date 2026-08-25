import Foundation
import OSLog
import BackgroundTasks
import HealthKit

class BackgroundSyncManager {
    static let shared = BackgroundSyncManager()
    private let logger = Logger(subsystem: "com.owen282000.lifedashboard", category: "BackgroundSync")

    static let healthSyncTaskId = "com.owen282000.lifedashboard.healthsync"
    static let healthRefreshTaskId = "com.owen282000.lifedashboard.healthrefresh"

    private let prefs = PreferencesManager.shared
    private let healthKitManager = HealthKitManager.shared

    private var observerQueries: [HKObserverQuery] = []
    private var pendingDataTypes: Set<HealthDataType> = []
    private var debounceTask: Task<Void, Never>?
    private let debounceSeconds: UInt64 = 5

    private init() {}

    // MARK: - Registration

    func registerBackgroundTasks() {
        // BGProcessingTask - runs when idle + charging (full catch-up sync)
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: BackgroundSyncManager.healthSyncTaskId,
            using: nil
        ) { task in
            self.handleHealthSync(task: task as! BGProcessingTask)
        }

        // BGAppRefreshTask - runs more frequently (every few hours), 30s window
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: BackgroundSyncManager.healthRefreshTaskId,
            using: nil
        ) { task in
            self.handleHealthRefresh(task: task as! BGAppRefreshTask)
        }
    }

    // MARK: - HKObserverQuery Setup

    /// Sets up HKObserverQuery for each enabled data type and enables background delivery.
    /// This is the primary sync mechanism - HealthKit wakes the app when new data arrives.
    func setupHealthKitObservers() {
        let enabledTypes = prefs.healthEnabledDataTypes

        // Stop existing observer queries
        for query in observerQueries {
            healthKitManager.healthStore.stop(query)
        }
        observerQueries.removeAll()

        guard !enabledTypes.isEmpty else { return }

        for dataType in enabledTypes {
            for sampleType in dataType.hkSampleTypes {
                // Create HKObserverQuery - fires when new samples of this type arrive
                let query = HKObserverQuery(
                    sampleType: sampleType,
                    predicate: nil
                ) { [weak self] _, completionHandler, error in
                    // MUST call completionHandler on every path or HealthKit
                    // permanently stops delivering background updates.
                    defer { completionHandler() }

                    guard error == nil else { return }
                    self?.handleHealthKitUpdate(for: dataType)
                }

                healthKitManager.healthStore.execute(query)
                observerQueries.append(query)

                // Enable background delivery (pairs with the observer query above)
                healthKitManager.healthStore.enableBackgroundDelivery(
                    for: sampleType,
                    frequency: .hourly
                ) { [logger] success, error in
                    if let error = error {
                        logger.error("Background delivery error for \(dataType.displayName): \(error)")
                    }
                }
            }
        }

        logger.info("HealthKit observers set up for \(enabledTypes.count) data types (\(self.observerQueries.count) queries)")
    }

    /// Reconfigures observers when user toggles data types on/off.
    func reconfigureObservers() {
        setupHealthKitObservers()
    }

    // MARK: - Debounced Sync Trigger

    /// Handles a HealthKit observer callback by collecting the data type and debouncing.
    /// Multiple observer callbacks within the debounce window are batched into a single sync.
    private func handleHealthKitUpdate(for dataType: HealthDataType) {
        pendingDataTypes.insert(dataType)

        debounceTask?.cancel()
        debounceTask = Task {
            try? await Task.sleep(nanoseconds: debounceSeconds * 1_000_000_000)
            guard !Task.isCancelled else { return }

            let typesToSync = self.pendingDataTypes
            self.pendingDataTypes.removeAll()

            guard !typesToSync.isEmpty else { return }

            logger.info("HealthKit observer triggered sync for: \(typesToSync.map { $0.displayName })")
            let _ = await HealthSyncManager.shared.performIncrementalSync(types: typesToSync)
        }
    }

    // MARK: - Background Task Scheduling

    /// Schedule BGProcessingTask - runs when idle + charging (full catch-up sync)
    func scheduleHealthSync() {
        let request = BGProcessingTaskRequest(identifier: BackgroundSyncManager.healthSyncTaskId)
        let interval = TimeInterval(prefs.healthSyncIntervalMinutes * 60)
        request.earliestBeginDate = Date(timeIntervalSinceNow: interval)
        request.requiresNetworkConnectivity = true

        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            logger.error("Failed to schedule health sync: \(error)")
        }
    }

    /// Schedule BGAppRefreshTask - runs every ~1 hour, 30s window, no charging needed
    func scheduleHealthRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: BackgroundSyncManager.healthRefreshTaskId)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 3600) // 1 hour

        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            logger.error("Failed to schedule health refresh: \(error)")
        }
    }

    // MARK: - Task Handlers

    private func handleHealthSync(task: BGProcessingTask) {
        // Schedule next sync
        scheduleHealthSync()

        let syncTask = Task {
            // First drain any pending items from the retry queue
            await HealthSyncManager.shared.drainPendingQueue()

            // Then do a full catch-up sync
            let result = await HealthSyncManager.shared.performSync()
            switch result {
            case .noData, .success:
                task.setTaskCompleted(success: true)
            case .failure:
                task.setTaskCompleted(success: false)
            }
        }

        task.expirationHandler = {
            syncTask.cancel()
        }
    }

    private func handleHealthRefresh(task: BGAppRefreshTask) {
        // Always reschedule for next time
        scheduleHealthRefresh()

        let enabledTypes = prefs.healthEnabledDataTypes
        guard !enabledTypes.isEmpty else {
            task.setTaskCompleted(success: true)
            return
        }

        let syncTask = Task {
            // Drain pending queue first (quick)
            await HealthSyncManager.shared.drainPendingQueue()

            // Incremental sync (anchor-based, fast - fits in 30s window)
            let result = await HealthSyncManager.shared.performIncrementalSync(types: enabledTypes)
            switch result {
            case .noData, .success:
                task.setTaskCompleted(success: true)
            case .failure:
                task.setTaskCompleted(success: false)
            }
        }

        task.expirationHandler = {
            syncTask.cancel()
        }
    }

}
