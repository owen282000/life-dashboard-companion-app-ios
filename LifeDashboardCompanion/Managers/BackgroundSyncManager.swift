import Foundation
import OSLog
import BackgroundTasks
import HealthKit

/// MainActor: observer queries, the debounce state, and scheduling are all managed
/// from the main actor; HealthKit and BGTaskScheduler callbacks hop over explicitly.
@MainActor
final class BackgroundSyncManager {
    static let shared = BackgroundSyncManager()
    private let logger = Logger(subsystem: "com.owen282000.lifedashboard", category: "BackgroundSync")

    static let healthSyncTaskId = "com.owen282000.lifedashboard.healthsync"
    static let healthRefreshTaskId = "com.owen282000.lifedashboard.healthrefresh"

    private let prefs = PreferencesManager.shared
    private let healthKitManager = HealthKitManager.shared

    private var observerQueries: [HKObserverQuery] = []
    private var pendingDataTypes: Set<HealthDataType> = []
    private lazy var observerBatcher = ObserverBatcher { [weak self] in
        await self?.syncPendingTypes()
    }
    /// How long a HealthKit wakeup may keep HealthKit waiting: the debounce, one read and one
    /// delivery fit comfortably, and it stays under the roughly 30 seconds iOS gives.
    nonisolated static let observerBudgetSeconds: TimeInterval = 25

    private init() {}

    // MARK: - Registration

    func registerBackgroundTasks() {
        // Handlers run on the main queue so they can safely enter this MainActor class

        // BGProcessingTask - runs when idle + charging (full catch-up sync)
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: BackgroundSyncManager.healthSyncTaskId,
            using: .main
        ) { task in
            MainActor.assumeIsolated {
                guard let task = task as? BGProcessingTask else { return }
                BackgroundSyncManager.shared.handleHealthSync(task: task)
            }
        }

        // BGAppRefreshTask - runs more frequently (every few hours), 30s window
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: BackgroundSyncManager.healthRefreshTaskId,
            using: .main
        ) { task in
            MainActor.assumeIsolated {
                guard let task = task as? BGAppRefreshTask else { return }
                BackgroundSyncManager.shared.handleHealthRefresh(task: task)
            }
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
                ) { _, completionHandler, error in
                    // HealthKit keeps the app running until the completion handler is called,
                    // and stops background delivery for an app that never calls it. So it is
                    // called once on every path: after the sync it triggered, or at the latest
                    // when the time budget runs out, never before the work.
                    let completion = OnceCallback { _ in completionHandler() }
                    guard error == nil else {
                        completion.call(true)
                        return
                    }
                    // The budget runs from HealthKit's own callback, not from whenever the main
                    // actor gets to it during a busy background launch.
                    DispatchQueue.global().asyncAfter(deadline: .now() + BackgroundSyncManager.observerBudgetSeconds) {
                        completion.call(false)
                    }
                    Task { @MainActor in
                        BackgroundSyncManager.shared.handleHealthKitUpdate(for: dataType, completion: completion)
                    }
                }

                healthKitManager.healthStore.execute(query)
                observerQueries.append(query)

                // Enable background delivery (pairs with the observer query above). Immediate:
                // HealthKit still holds some types, such as steps, to hourly on its own, and
                // the others wake the app as soon as new samples are saved.
                healthKitManager.healthStore.enableBackgroundDelivery(
                    for: sampleType,
                    frequency: .immediate
                ) { [logger] _, error in
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

    /// Handles a HealthKit observer callback: the type joins the next batch, and the wakeup's
    /// completion handler is called when the sync that batch goes into has ended.
    private func handleHealthKitUpdate(for dataType: HealthDataType, completion: OnceCallback) {
        pendingDataTypes.insert(dataType)
        observerBatcher.add(completion)
    }

    private func syncPendingTypes() async {
        let typesToSync = pendingDataTypes
        pendingDataTypes.removeAll()
        guard !typesToSync.isEmpty else { return }

        logger.info("HealthKit observer triggered sync for: \(typesToSync.map { $0.displayName })")
        _ = await HealthSyncManager.shared.performIncrementalSync(types: typesToSync)
    }

    // MARK: - Background Task Scheduling

    /// Schedule BGProcessingTask - runs when idle + charging (full catch-up sync)
    func scheduleHealthSync() {
        let request = BGProcessingTaskRequest(identifier: BackgroundSyncManager.healthSyncTaskId)
        let interval = TimeInterval(prefs.healthSyncIntervalMinutes * 60)
        request.earliestBeginDate = Date(timeIntervalSinceNow: interval)
        request.requiresNetworkConnectivity = true

        submit(request, name: "health sync")
    }

    /// Schedule BGAppRefreshTask - runs every ~1 hour, 30s window, no charging needed
    func scheduleHealthRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: BackgroundSyncManager.healthRefreshTaskId)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 3600) // 1 hour

        submit(request, name: "health refresh")
    }

    /// Submits a background task request and says why when iOS refuses it. `notPermitted` is a
    /// build problem (a missing background mode or identifier) and would otherwise go unnoticed;
    /// `unavailable` is expected in the Simulator and when Background App Refresh is off.
    private func submit(_ request: BGTaskRequest, name: String) {
        do {
            try BGTaskScheduler.shared.submit(request)
            logger.info("Scheduled \(name, privacy: .public) for \(request.earliestBeginDate?.description ?? "now", privacy: .public)")
        } catch let error as BGTaskScheduler.Error {
            switch error.code {
            case .notPermitted:
                logger.fault("iOS refused the \(name, privacy: .public) task: background mode or identifier missing from Info.plist")
            case .unavailable:
                logger.notice("Background tasks unavailable for \(name, privacy: .public): Simulator, or Background App Refresh is off")
            case .tooManyPendingTaskRequests:
                logger.error("Too many pending background task requests for \(name, privacy: .public)")
            default:
                logger.error("Failed to schedule \(name, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        } catch {
            logger.error("Failed to schedule \(name, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Task Handlers

    private func handleHealthSync(task: BGProcessingTask) {
        // Schedule next sync
        scheduleHealthSync()

        runBackgroundTask(task) {
            // First drain any pending items from the retry queue
            await HealthSyncManager.shared.drainPendingQueue()

            // Then do a full catch-up sync
            return await HealthSyncManager.shared.performSync()
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

        runBackgroundTask(task) {
            // Drain pending queue first (quick)
            await HealthSyncManager.shared.drainPendingQueue()

            // Incremental sync (anchor-based, fast - fits in 30s window)
            return await HealthSyncManager.shared.performIncrementalSync(types: enabledTypes)
        }
    }

    /// Runs the work of a background task and completes the task exactly once: when the work
    /// ends, or when iOS says the time is up, whichever comes first. A HealthKit query or a
    /// webhook that does not answer then cannot keep the task open until the system kills the app.
    private func runBackgroundTask(_ task: BGTask, work: @escaping @MainActor () async -> HealthSyncResult) {
        let completion = OnceCallback { success in task.setTaskCompleted(success: success) }
        let holder = TaskHolder()
        task.expirationHandler = {
            holder.cancel()
            completion.call(false)
        }
        holder.task = Task { @MainActor in
            let result = await work()
            switch result {
            case .noData, .success:
                completion.call(true)
            case .failure:
                completion.call(false)
            }
        }
    }

}

/// A completion that runs once, however many paths reach it. An HKObserverQuery completion is
/// called by the end of its sync and by the time budget; a background task is completed by its
/// work and by its expiration handler. Only the first call gets through.
final class OnceCallback: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: ((Bool) -> Void)?

    init(_ handler: @escaping (Bool) -> Void) {
        self.handler = handler
    }

    func call(_ success: Bool) {
        lock.lock()
        let pending = handler
        handler = nil
        lock.unlock()
        pending?(success)
    }
}

/// Lets an expiration handler, which iOS may call on any thread, cancel the work task.
private final class TaskHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var current: Task<Void, Never>?

    var task: Task<Void, Never>? {
        get { lock.withLock { current } }
        set {
            let cancelNow = lock.withLock { () -> Bool in
                current = newValue
                return cancelled
            }
            if cancelNow { newValue?.cancel() }
        }
    }

    func cancel() {
        let task = lock.withLock { () -> Task<Void, Never>? in
            cancelled = true
            return current
        }
        task?.cancel()
    }
}

/// Batches HealthKit wakeups into one sync. A wakeup waits for the debounce, restarted by each
/// later one, but never longer than `maxWait` after the first of the batch, so a steady stream
/// of samples during a workout still syncs. The timers only decide when to start; the sync runs
/// in a task of its own that no later wakeup cancels. Wakeups that arrive while it runs form the
/// next batch, which starts when this one ends.
@MainActor
final class ObserverBatcher {
    typealias Sleep = @Sendable (TimeInterval) async -> Void

    private let debounce: TimeInterval
    private let maxWait: TimeInterval
    private let sleep: Sleep
    private let run: @MainActor () async -> Void

    private var pending: [OnceCallback] = []
    private var debounceTimer: Task<Void, Never>?
    private var maxWaitTimer: Task<Void, Never>?
    private var isRunning = false

    init(
        debounce: TimeInterval = 5,
        maxWait: TimeInterval = 10,
        sleep: @escaping Sleep = { try? await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) },
        run: @escaping @MainActor () async -> Void
    ) {
        self.debounce = debounce
        self.maxWait = maxWait
        self.sleep = sleep
        self.run = run
    }

    func add(_ completion: OnceCallback) {
        pending.append(completion)
        guard !isRunning else { return }
        debounceTimer?.cancel()
        debounceTimer = timer(after: debounce)
        if maxWaitTimer == nil {
            maxWaitTimer = timer(after: maxWait)
        }
    }

    private func timer(after delay: TimeInterval) -> Task<Void, Never> {
        Task { [sleep] in
            await sleep(delay)
            guard !Task.isCancelled else { return }
            self.fire()
        }
    }

    private func fire() {
        debounceTimer?.cancel()
        maxWaitTimer?.cancel()
        debounceTimer = nil
        maxWaitTimer = nil
        guard !isRunning, !pending.isEmpty else { return }

        let batch = pending
        pending.removeAll()
        isRunning = true
        Task {
            await self.run()
            batch.forEach { $0.call(true) }
            self.isRunning = false
            if !self.pending.isEmpty {
                self.fire()
            }
        }
    }
}
