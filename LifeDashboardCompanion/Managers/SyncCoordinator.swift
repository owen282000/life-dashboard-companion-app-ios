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
        var drain: @Sendable () async -> Void
        var syncIncremental: @Sendable () async -> HealthSyncResult
        var syncFull: @Sendable () async -> HealthSyncResult
        /// Re-aims the background task requests; true after a run the lock stopped.
        var replan: @Sendable (_ afterLockedRun: Bool) async -> Void
    }

    static let shared = SyncCoordinator(environment: .live)

    private let env: Environment
    private var flight: Task<Void, Never>?
    private var flightNumber = 0

    init(environment: Environment) {
        self.env = environment
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
            await env.drain()
            guard !Task.isCancelled else { return .cancelled }
            let result = await env.syncIncremental()
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

    /// Sync Now (a full read) and the Shortcuts action (new records only): never held back by
    /// the schedule and never recorded, but never beside another run either.
    func runManual(full: Bool) async -> HealthSyncResult {
        while let flight { await wait(for: flight) }
        let env = self.env
        let result = await fly { () -> HealthSyncResult in
            await env.drain()
            return full ? await env.syncFull() : await env.syncIncremental()
        }
        await env.replan(false)
        return result
    }

    // MARK: - Retry queue

    /// Delivers what earlier syncs queued. An automatic retry (app launch, the network coming
    /// back) waits for quiet hours; Retry Now does not.
    func drain(automatic: Bool) async {
        if automatic, !env.schedule().allowsDelivery(at: env.now(), timeZone: env.timeZone()) { return }
        if let flight {
            // Every run drains first, and the drain itself runs once more for late arrivals.
            await wait(for: flight)
            return
        }
        let env = self.env
        await fly { await env.drain() }
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
    @discardableResult
    private func fly<Value: Sendable>(_ operation: @escaping @Sendable () async -> Value) async -> Value {
        let priority = max(Task.currentPriority, .utility)
        let work = Task(priority: priority, operation: operation)
        flightNumber += 1
        let number = flightNumber
        flight = Task(priority: priority) {
            _ = await work.value
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
        drain: { await HealthSyncManager.shared.drainPendingQueue() },
        syncIncremental: {
            await HealthSyncManager.shared.performIncrementalSync(types: PreferencesManager.shared.healthEnabledDataTypes)
        },
        syncFull: { await HealthSyncManager.shared.performSync() },
        replan: { afterLockedRun in await BackgroundSyncManager.shared.replan(afterLockedRun: afterLockedRun) }
    )
}
