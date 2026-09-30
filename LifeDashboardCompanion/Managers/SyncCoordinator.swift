import Foundation
import UIKit

/// The chances iOS gives the app to sync on its own.
enum SyncTrigger: String, Sendable {
    case observer, appRefresh, processing, foreground, unlock
}

enum AutomaticSyncOutcome: Equatable, Sendable {
    /// No webhook URL or no data type: nothing to do.
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

    init(environment: Environment) {
        self.env = environment
    }

    // MARK: - Automatic

    func runAutomatic(_ trigger: SyncTrigger) async -> AutomaticSyncOutcome {
        if let flight {
            // Whatever runs now covers this chance; ask again once it is done, since a manual
            // sync records nothing and a scheduled time may still be owed.
            await flight.value
            if self.flight != nil { return .notDue }
        }
        guard env.isConfigured() else { return .notConfigured }

        let startedAt = env.now()
        guard case .due(let slot) = env.schedule().decide(state: env.loadState(), now: startedAt, timeZone: env.timeZone()) else {
            return .notDue
        }

        let env = self.env
        let work = Task { () -> AutomaticSyncOutcome in
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
        let outcome = await fly(work)
        await env.replan(outcome == .locked)
        return outcome
    }

    // MARK: - Manual

    /// Sync Now (a full read) and the Shortcuts action (new records only): never held back by
    /// the schedule and never recorded, but never beside another run either.
    func runManual(full: Bool) async -> HealthSyncResult {
        while let flight { await flight.value }
        let env = self.env
        let work = Task { () -> HealthSyncResult in
            await env.drain()
            return full ? await env.syncFull() : await env.syncIncremental()
        }
        let result = await fly(work)
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
            await flight.value
            return
        }
        let env = self.env
        await fly(Task { await env.drain() })
    }

    // MARK: - Flight

    /// Runs `work` as the one flight. Cancelling the caller cancels the work, which is how a
    /// background task that runs out of time stops its run.
    @discardableResult
    private func fly<Value: Sendable>(_ work: Task<Value, Never>) async -> Value {
        let marker = Task { _ = await work.value }
        flight = marker
        let value = await withTaskCancellationHandler {
            await work.value
        } onCancel: {
            work.cancel()
        }
        if flight == marker { flight = nil }
        return value
    }
}

extension SyncCoordinator.Environment {
    static let live = SyncCoordinator.Environment(
        now: { Date() },
        timeZone: { TimeZone.autoupdatingCurrent },
        isUnlocked: { await MainActor.run { UIApplication.shared.isProtectedDataAvailable } },
        isConfigured: {
            let prefs = PreferencesManager.shared
            return !prefs.healthWebhookUrls.isEmpty && !prefs.healthEnabledDataTypes.isEmpty
        },
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
