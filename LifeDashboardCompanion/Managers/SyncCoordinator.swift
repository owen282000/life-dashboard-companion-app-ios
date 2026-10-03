import Foundation
import UIKit

/// The chances iOS gives the app to sync on its own.
enum SyncTrigger: String, Sendable {
    case observer, appRefresh, processing, foreground, unlock
}

enum AutomaticSyncOutcome: Equatable, Sendable {
    /// No destination (webhook URL or MQTT broker) or no data type: nothing to do.
    case notConfigured
    /// The schedule says no, or a run already in progress covered this chance.
    case notDue
    /// The iPhone was locked, so Health data could not be read; the sync stays owed.
    case locked
    /// Stopped before HealthKit was read (a background task ran out of time).
    case cancelled
    case ran(success: Bool)
}

/// Every sync and every retry of the queue goes through here, one at a time.
///
/// Automatic chances (a HealthKit wakeup, a background task, opening the app, unlocking) ask
/// the schedule and run only when it says so; Sync Now, Retry Now and the Shortcuts action
/// ignore it, as manual syncs do on Android, but wait for a run in progress instead of running
/// beside it. The run is claimed in the same actor turn as the decision, so two chances that
/// arrive together cannot both pass the gate. The schedule's state is written only once
/// HealthKit was read: a locked iPhone or a run stopped before the read leaves the sync owed.
/// A manual sync records nothing.
///
/// The Shortcuts action runs in the app process, so one flight in this process is enough.
/// HealthSyncManager keeps a SingleFlight of its own around the incremental sync and the queue
/// drain; with every caller coming through here they never find a run in progress, and they
/// are there for a caller that does not.
actor SyncCoordinator {
    struct Environment: Sendable {
        var now: @Sendable () -> Date
        var timeZone: @Sendable () -> TimeZone
        var isUnlocked: @Sendable () async -> Bool
        var isConfigured: @Sendable () -> Bool
        var schedule: @Sendable () -> SyncSchedule
        var loadState: @Sendable () -> ScheduleState
        var saveState: @Sendable (ScheduleState) -> Void
        /// Delivers the retry queue; true for Retry Now, which also offers what a receiver
        /// refused less than a day ago.
        var drain: @Sendable (_ retryRefused: Bool) async -> Void
        var syncIncremental: @Sendable () async -> HealthSyncResult
        /// Sync Now in the app: the incremental sync in catch-up passes, and every type's
        /// newest value to MQTT.
        var syncNow: @Sendable () async -> HealthSyncResult
        /// Re-aims the background task requests; true after a run the lock stopped.
        var replan: @Sendable (_ afterLockedRun: Bool) async -> Void
        /// Asks iOS for time to finish a run that started while the app was in the foreground,
        /// and returns how to give it back; nil in the background, where the HealthKit wakeup
        /// or the background task already holds the app. `expired` is called when iOS wants
        /// the time back first.
        var holdInForeground: @Sendable (_ expired: @escaping @Sendable () -> Void) async -> (@Sendable () -> Void)?
    }

    static let shared = SyncCoordinator(environment: .live)

    private let env: Environment
    private var flight: Task<Void, Never>?
    private var flightNumber = 0

    /// Where this actor's code runs. In the app that is a plain actor's own queue, as for any
    /// actor; a test passes an executor of its own to decide which caller gets in first.
    private let executor: (any SerialExecutor)?
    private let lane = Lane()
    private actor Lane {}

    nonisolated var unownedExecutor: UnownedSerialExecutor {
        executor?.asUnownedSerialExecutor() ?? lane.unownedExecutor
    }

    init(environment: Environment, executor: (any SerialExecutor)? = nil) {
        self.env = environment
        self.executor = executor
    }

    // MARK: - Automatic

    func runAutomatic(_ trigger: SyncTrigger) async -> AutomaticSyncOutcome {
        if let flight {
            // Whatever runs now covers this chance; ask again once it is done, since a manual
            // sync records nothing and a scheduled time may still be owed.
            await wait(for: flight)
            if self.flight != nil { return .notDue }
        }
        guard env.isConfigured() else { return .notConfigured }

        let startedAt = env.now()
        guard case .due(let slot) = env.schedule().decide(state: env.loadState(), now: startedAt, timeZone: env.timeZone()) else {
            return .notDue
        }

        let env = self.env
        let outcome = await fly { () -> AutomaticSyncOutcome in
            guard await env.isUnlocked() else { return .locked }
            await env.drain(false)
            guard !Task.isCancelled else { return .cancelled }
            let result = await env.syncIncremental()
            // Cut off mid-sync: what it sent is sent and the rest is queued or still ahead of
            // the anchors, but the scheduled time stays owed.
            guard !Task.isCancelled else { return .cancelled }
            if case .failure = result, await !env.isUnlocked() {
                // Locked while reading: nothing was read, so the time stays owed.
                return .locked
            }
            var state = env.loadState()
            state.lastRun = startedAt
            if let slot { state.lastSlot = slot }
            env.saveState(state)
            if case .failure = result { return .ran(success: false) }
            return .ran(success: true)
        }
        await env.replan(outcome == .locked)
        return outcome
    }

    // MARK: - Manual

    /// Sync Now (new records, in catch-up passes) and the Shortcuts action (one round of new
    /// records): never held back by the schedule and never recorded, but never beside another
    /// run either.
    func runManual(syncNow: Bool) async -> HealthSyncResult {
        while let flight { await wait(for: flight) }
        let env = self.env
        let result = await fly { () -> HealthSyncResult in
            await env.drain(false)
            return syncNow ? await env.syncNow() : await env.syncIncremental()
        }
        await env.replan(false)
        return result
    }

    // MARK: - Retry queue

    /// Delivers what earlier syncs queued. An automatic retry (app launch, the network coming
    /// back) waits for quiet hours; Retry Now does not.
    func drain(automatic: Bool) async {
        if automatic, !env.schedule().allowsDelivery(at: env.now(), timeZone: env.timeZone()) { return }
        while let flight {
            // Every run drains first, and the drain itself runs once more for late arrivals.
            await wait(for: flight)
            // That drain left alone what was refused today, which Retry Now offers as well.
            if automatic { return }
        }
        let env = self.env
        await fly { await env.drain(!automatic) }
    }

    // MARK: - Flight

    /// Callers inside a wait for the flight, counted until they are back on this actor. Tests
    /// read it to know a caller is queued.
    private(set) var waiting = 0

    /// Runs `operation` as the one flight. Cancelling the caller cancels the work, which is how a
    /// background task that runs out of time stops its run.
    ///
    /// The flight clears itself on this actor before it completes, so a caller that waited for
    /// it finds it gone or replaced. Cleared by the owner after its own wait, a finished flight
    /// could still be set when a waiter of higher priority got the actor first; awaiting a
    /// finished task returns at once, so that waiter looped and the owner never got in.
    ///
    /// The flight runs at utility priority or higher, whoever started it. Sync Now waits for it,
    /// and that wait does not reliably lift work at background priority: on a busy machine such
    /// work went seconds without a CPU, and Sync Now waited with it.
    ///
    /// A run started in the foreground, Sync Now or opening the app, asks iOS for background
    /// time, so leaving the app mid-POST does not suspend it there. When iOS takes the time back,
    /// the work is cancelled like a background task that ran out: a delivery in flight ends as
    /// interrupted, and its payload is already in the retry queue.
    @discardableResult
    private func fly<Value: Sendable>(_ operation: @escaping @Sendable () async -> Value) async -> Value {
        let priority = max(Task.currentPriority, .utility)
        let work = Task(priority: priority, operation: operation)
        flightNumber += 1
        let number = flightNumber
        let hold = env.holdInForeground
        // Asked inside the flight, not here: an await before `flight` is set would let a second
        // caller in to start a run of its own.
        flight = Task(priority: priority) {
            let release = await hold { work.cancel() }
            _ = await work.value
            release?()
            self.land(number)
        }
        return await withTaskCancellationHandler {
            await work.value
        } onCancel: {
            work.cancel()
        }
    }

    private func land(_ number: Int) {
        if number == flightNumber { flight = nil }
    }

    private func wait(for flight: Task<Void, Never>) async {
        waiting += 1
        await flight.value
        waiting -= 1
    }
}

extension SyncCoordinator.Environment {
    static let live = SyncCoordinator.Environment(
        now: { Date() },
        timeZone: { TimeZone.autoupdatingCurrent },
        isUnlocked: { await MainActor.run { UIApplication.shared.isProtectedDataAvailable } },
        isConfigured: { PreferencesManager.shared.healthSyncConfigured },
        schedule: { PreferencesManager.shared.healthSyncSchedule },
        loadState: { PreferencesManager.shared.healthScheduleState },
        saveState: { PreferencesManager.shared.healthScheduleState = $0 },
        drain: { retryRefused in await HealthSyncManager.shared.drainPendingQueue(retryRefused: retryRefused) },
        syncIncremental: {
            await HealthSyncManager.shared.performIncrementalSync(types: PreferencesManager.shared.healthEnabledDataTypes)
        },
        syncNow: { await HealthSyncManager.shared.performSyncNow() },
        replan: { afterLockedRun in await BackgroundSyncManager.shared.replan(afterLockedRun: afterLockedRun) },
        holdInForeground: { expired in await MainActor.run { ForegroundHold.begin(expired: expired) } }
    )
}

/// A UIKit background task for a run that started in the foreground: iOS gives the app about
/// 30 seconds after it leaves the screen, instead of suspending it in the middle of a POST.
@MainActor
enum ForegroundHold {
    static func begin(expired: @escaping @Sendable () -> Void) -> (@Sendable () -> Void)? {
        let app = UIApplication.shared
        guard wanted(in: app.applicationState) else { return nil }
        let token = Token()
        // Once, whoever gets there first: the end of the run, off the main thread, or iOS
        // taking the time back, on it. An expired task still open when its handler returns
        // gets the app terminated, so that path ends it right there.
        let end = OnceCallback { @Sendable onMain in
            if onMain {
                MainActor.assumeIsolated { UIApplication.shared.endBackgroundTask(token.id) }
            } else {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { UIApplication.shared.endBackgroundTask(token.id) }
                }
            }
        }
        token.id = app.beginBackgroundTask(withName: "Health sync") {
            expired()
            end.call(true)
        }
        guard token.id != .invalid else { return nil }
        return { end.call(false) }
    }

    /// On screen, or on its way there or away: a HealthKit wakeup or a background task runs
    /// in the background and holds the app itself.
    nonisolated static func wanted(in state: UIApplication.State) -> Bool {
        state != .background
    }

    private final class Token: @unchecked Sendable {
        var id: UIBackgroundTaskIdentifier = .invalid
    }
}
