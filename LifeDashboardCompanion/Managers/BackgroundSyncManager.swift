import Foundation
import OSLog
import BackgroundTasks
import HealthKit
import UIKit

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
    private lazy var observerBatcher = ObserverBatcher(run: BackgroundSyncManager.runObserverSync)
    private var replanTask: Task<Void, Never>?
    private var notificationTokens: [NSObjectProtocol] = []
    /// How long a HealthKit wakeup may keep HealthKit waiting: the debounce, one read and one
    /// delivery fit comfortably, and it stays under the roughly 30 seconds iOS gives. The sync
    /// of the batch is cancelled when the first wakeup in it reaches this, since iOS may suspend
    /// the app from then on: a post cut off there ends as interrupted, with its payload already
    /// queued, instead of hanging until the app comes back and then counting as failed.
    nonisolated static let observerBudgetSeconds: TimeInterval = 25

    private init() {}

    // MARK: - Registration

    func registerBackgroundTasks() {
        // Handlers run on the main queue so they can safely enter this MainActor class

        // BGProcessingTask - runs when the device is idle: a chance for the scheduled sync (new records)
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: BackgroundSyncManager.healthSyncTaskId,
            using: .main
        ) { task in
            MainActor.assumeIsolated {
                guard let task = task as? BGProcessingTask else { return }
                BackgroundSyncManager.shared.handleHealthSync(task: task)
            }
        }

        // BGAppRefreshTask - about 30 s, when iOS chooses: a chance for the scheduled sync
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
                    let budgetEnd = Date().addingTimeInterval(BackgroundSyncManager.observerBudgetSeconds)
                    DispatchQueue.global().asyncAfter(deadline: .now() + BackgroundSyncManager.observerBudgetSeconds) {
                        completion.call(false)
                    }
                    Task { @MainActor in
                        BackgroundSyncManager.shared.handleHealthKitUpdate(for: dataType, completion: completion, budgetEnd: budgetEnd)
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
                        logger.error("Background delivery error for \(dataType.rawValue): \(error)")
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

    /// Handles a HealthKit observer callback. The schedule is asked first: a wakeup that is not
    /// due releases HealthKit at once. One that is due joins the next batch, and its completion
    /// handler is called when the sync that batch goes into has ended. The sync reads every
    /// enabled type, since a scheduled sync is about all of them, not the one that woke the app.
    private func handleHealthKitUpdate(for dataType: HealthDataType, completion: OnceCallback, budgetEnd: Date) {
        guard case .due = prefs.healthSyncSchedule.decide(
            state: prefs.healthScheduleState, now: Date(), timeZone: .autoupdatingCurrent
        ) else {
            completion.call(true)
            return
        }
        logger.info("HealthKit update for \(dataType.rawValue, privacy: .public), sync due")
        observerBatcher.add(completion, budgetEnd: budgetEnd)
    }

    private static func runObserverSync() async {
        _ = await SyncCoordinator.shared.runAutomatic(.observer)
    }

    // MARK: - Schedule changes and other chances

    /// Follows what changes the next sync: an edit of the schedule, the clock or the time zone,
    /// and the iPhone being unlocked, which is the first moment a sync the lock held back can run.
    func startObservingScheduleChanges() {
        guard notificationTokens.isEmpty else { return }
        let center = NotificationCenter.default
        let replanNames: [Notification.Name] = [
            .healthSyncScheduleDidChange,
            UIApplication.significantTimeChangeNotification,
            .NSSystemTimeZoneDidChange
        ]
        for name in replanNames {
            notificationTokens.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { BackgroundSyncManager.shared.scheduleDidChange() }
            })
        }
        notificationTokens.append(center.addObserver(
            forName: .healthDestinationsDidChange, object: prefs, queue: .main
        ) { _ in
            MainActor.assumeIsolated { BackgroundSyncManager.shared.scheduleDidChange() }
        })
        notificationTokens.append(center.addObserver(
            forName: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil, queue: .main
        ) { _ in
            Task { _ = await SyncCoordinator.shared.runAutomatic(.unlock) }
        })
    }

    /// Settings save on every change, so a DatePicker being turned or a number being typed
    /// would re-aim the requests many times a second; one second of quiet is enough. A change
    /// of destination comes here too: the first webhook URL or broker starts the observers.
    func scheduleDidChange() {
        replanTask?.cancel()
        replanTask = Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            start()
        }
    }

    /// Sets up the observers when there is a destination and none are running yet, and aims
    /// the background tasks. At launch, and after every change of schedule or destination, so
    /// a broker or webhook URL added later needs no relaunch.
    func start() {
        if observerQueries.isEmpty && prefs.healthSyncConfigured {
            setupHealthKitObservers()
        }
        replan()
    }

    // MARK: - Background Task Scheduling

    /// Aims both background tasks at the next moment the schedule allows a sync, or cancels them
    /// when it never does. iOS treats the moment as "not before" and picks the real one itself;
    /// every run, edit and clock change calls this again, and a new request replaces the old one.
    /// After a run the lock stopped, it waits a quarter of an hour instead of asking at once.
    func replan(afterLockedRun: Bool = false) {
        let now = Date()
        let hasWork = prefs.healthSyncConfigured
        let decision = prefs.healthSyncSchedule.decide(state: prefs.healthScheduleState, now: now, timeZone: .autoupdatingCurrent)
        var target: Date
        switch decision {
        case .never:
            cancelBackgroundTasks()
            return
        case _ where !hasWork:
            cancelBackgroundTasks()
            return
        case .due:
            // Due now: HealthKit or opening the app usually gets there first.
            target = now.addingTimeInterval(60)
        case .wait(let until):
            target = until
        }
        if afterLockedRun {
            target = max(target, now.addingTimeInterval(15 * 60))
        }

        let refresh = BGAppRefreshTaskRequest(identifier: BackgroundSyncManager.healthRefreshTaskId)
        refresh.earliestBeginDate = target
        submit(refresh, name: "health refresh")

        let processing = BGProcessingTaskRequest(identifier: BackgroundSyncManager.healthSyncTaskId)
        processing.earliestBeginDate = target
        processing.requiresNetworkConnectivity = true
        submit(processing, name: "health sync")
    }

    private func cancelBackgroundTasks() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: BackgroundSyncManager.healthRefreshTaskId)
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: BackgroundSyncManager.healthSyncTaskId)
        logger.info("No automatic sync to schedule")
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

    /// Both tasks are chances for the scheduled sync: the refresh task runs for about 30
    /// seconds, the processing task longer and only while the iPhone is idle. Neither resends
    /// the last seven days any more; the new records since the last sync are what is due.
    private func handleHealthSync(task: BGProcessingTask) {
        runBackgroundTask(task, trigger: .processing)
    }

    private func handleHealthRefresh(task: BGAppRefreshTask) {
        runBackgroundTask(task, trigger: .appRefresh)
    }

    /// Runs the work of a background task and completes the task exactly once: when the work
    /// ends, or when iOS says the time is up, whichever comes first. A HealthKit query or a
    /// webhook that does not answer then cannot keep the task open until the system kills the app.
    /// The coordinator re-aims both requests when the run ends; a run that did not happen
    /// re-aims them here, since iOS dropped the request that launched this task.
    private func runBackgroundTask(_ task: BGTask, trigger: SyncTrigger) {
        let completion = OnceCallback { success in task.setTaskCompleted(success: success) }
        let holder = TaskHolder()
        task.expirationHandler = {
            holder.cancel()
            completion.call(false)
        }
        holder.task = Task { @MainActor in
            let outcome = await SyncCoordinator.shared.runAutomatic(trigger)
            switch outcome {
            case .ran(let success):
                completion.call(success)
            case .locked, .cancelled:
                completion.call(false)
            case .notDue, .notConfigured:
                self.replan()
                completion.call(true)
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
///
/// A wakeup can bring the end of its time budget. The sync of a batch is cancelled at the
/// earliest of them, which is when HealthKit is let go and iOS may suspend the app.
@MainActor
final class ObserverBatcher {
    typealias Sleep = @Sendable (TimeInterval) async -> Void

    private let debounce: TimeInterval
    private let maxWait: TimeInterval
    private let sleep: Sleep
    private let now: @Sendable () -> Date
    private let run: @MainActor () async -> Void

    private var pending: [(completion: OnceCallback, budgetEnd: Date?)] = []
    private var debounceTimer: Task<Void, Never>?
    private var maxWaitTimer: Task<Void, Never>?
    private var isRunning = false

    init(
        debounce: TimeInterval = 5,
        maxWait: TimeInterval = 10,
        sleep: @escaping Sleep = { try? await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) },
        now: @escaping @Sendable () -> Date = { Date() },
        run: @escaping @MainActor () async -> Void
    ) {
        self.debounce = debounce
        self.maxWait = maxWait
        self.sleep = sleep
        self.now = now
        self.run = run
    }

    func add(_ completion: OnceCallback, budgetEnd: Date? = nil) {
        pending.append((completion, budgetEnd))
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
        let work = Task { await self.run() }
        let watchdog = batch.compactMap(\.budgetEnd).min().map { end in
            Task { [sleep, now] in
                await sleep(max(0, end.timeIntervalSince(now())))
                guard !Task.isCancelled else { return }
                work.cancel()
            }
        }
        Task {
            await work.value
            watchdog?.cancel()
            batch.forEach { $0.completion.call(true) }
            self.isRunning = false
            if !self.pending.isEmpty {
                self.fire()
            }
        }
    }
}
