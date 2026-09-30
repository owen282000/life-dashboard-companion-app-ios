import XCTest
@testable import LifeDashboardCompanion

final class SyncCoordinatorTests: XCTestCase {

    /// The outside world of the coordinator: clock, lock state, settings and the sync itself.
    private final class World: @unchecked Sendable {
        private let lock = NSLock()
        private var _now = Date(timeIntervalSince1970: 1_789_380_000) // 2026-09-14 10:00 UTC, a Monday
        private var _unlocked = true
        private var _schedule = SyncSchedule()
        private var _state = ScheduleState(changedAt: Date(timeIntervalSince1970: 1_789_300_000))
        private var _result: HealthSyncResult = .success(syncCounts: [:])
        private(set) var drains = 0
        private(set) var incrementals = 0
        private(set) var fulls = 0
        private(set) var replans: [Bool] = []
        private var _events: [String] = []
        let syncLatch = Latch()
        let drainLatch = Latch()

        var now: Date { get { lock.withLock { _now } } set { lock.withLock { _now = newValue } } }
        var unlocked: Bool { get { lock.withLock { _unlocked } } set { lock.withLock { _unlocked = newValue } } }
        var schedule: SyncSchedule { get { lock.withLock { _schedule } } set { lock.withLock { _schedule = newValue } } }
        var state: ScheduleState { get { lock.withLock { _state } } set { lock.withLock { _state = newValue } } }
        var result: HealthSyncResult { get { lock.withLock { _result } } set { lock.withLock { _result = newValue } } }

        /// What the runs did, in order: where each read started and ended.
        var events: [String] { lock.withLock { _events } }

        func count(_ body: (World) -> Void) { lock.withLock { body(self) } }
        func addDrain() { lock.withLock { drains += 1; _events.append("drain") } }
        func addIncremental() { lock.withLock { incrementals += 1; _events.append("incremental") } }
        func addFull() { lock.withLock { fulls += 1; _events.append("full") } }
        func addReplan(_ locked: Bool) { lock.withLock { replans.append(locked) } }
        func note(_ event: String) { lock.withLock { _events.append(event) } }

        var environment: SyncCoordinator.Environment {
            SyncCoordinator.Environment(
                now: { self.now },
                timeZone: { TimeZone(identifier: "UTC")! },
                isUnlocked: { self.unlocked },
                isConfigured: { true },
                schedule: { self.schedule },
                loadState: { self.state },
                saveState: { self.state = $0 },
                drain: {
                    self.addDrain()
                    await self.drainLatch.wait()
                },
                syncIncremental: {
                    self.addIncremental()
                    await self.syncLatch.wait()
                    self.note("incremental done")
                    return self.result
                },
                syncFull: {
                    self.addFull()
                    await self.syncLatch.wait()
                    self.note("full done")
                    return self.result
                },
                replan: { self.addReplan($0) }
            )
        }
    }

    private func openWorld() async -> World {
        let world = World()
        await world.syncLatch.open()
        await world.drainLatch.open()
        return world
    }

    func testADueRunDrainsSyncsAndRecordsItsStartTime() async {
        let world = await openWorld()
        let coordinator = SyncCoordinator(environment: world.environment)

        let outcome = await coordinator.runAutomatic(.observer)

        XCTAssertEqual(outcome, .ran(success: true))
        XCTAssertEqual(world.drains, 1)
        XCTAssertEqual(world.incrementals, 1)
        XCTAssertEqual(world.state.lastRun, world.now)
        XCTAssertEqual(world.replans, [false])
    }

    func testAFixedTimeRunRecordsTheTimeItRanFor() async {
        let world = await openWorld()
        world.schedule = SyncSchedule(mode: .times, times: [TimeOfDay(hour: 8, minute: 0)])
        let coordinator = SyncCoordinator(environment: world.environment)

        let outcome = await coordinator.runAutomatic(.appRefresh)

        XCTAssertEqual(outcome, .ran(success: true))
        XCTAssertEqual(world.state.lastSlot, LocalDateTime(Date(timeIntervalSince1970: 1_789_372_800), in: TimeZone(identifier: "UTC")!))
    }

    func testNothingNewAndAQueuedFailureBothCountAsARun() async {
        let world = await openWorld()
        world.result = .noData
        let coordinator = SyncCoordinator(environment: world.environment)
        _ = await coordinator.runAutomatic(.observer)
        XCTAssertEqual(world.state.lastRun, world.now)

        world.state.lastRun = nil
        world.result = .failure(error: "Webhook failed - queued for retry")
        let outcome = await coordinator.runAutomatic(.observer)
        XCTAssertEqual(outcome, .ran(success: false))
        XCTAssertEqual(world.state.lastRun, world.now)
    }

    func testALockedIPhoneDoesNotUseUpTheSync() async {
        let world = await openWorld()
        world.unlocked = false
        let coordinator = SyncCoordinator(environment: world.environment)

        let outcome = await coordinator.runAutomatic(.observer)

        XCTAssertEqual(outcome, .locked)
        XCTAssertEqual(world.incrementals, 0)
        XCTAssertNil(world.state.lastRun)
        XCTAssertEqual(world.replans, [true])
    }

    func testANotDueChanceDoesNothing() async {
        let world = await openWorld()
        world.state.lastRun = world.now.addingTimeInterval(-600)
        let coordinator = SyncCoordinator(environment: world.environment)

        let outcome = await coordinator.runAutomatic(.foreground)

        XCTAssertEqual(outcome, .notDue)
        XCTAssertEqual(world.drains, 0)
        XCTAssertEqual(world.incrementals, 0)
    }

    func testChancesThatArriveTogetherRunOneSync() async {
        let world = World()
        await world.drainLatch.open()
        let coordinator = SyncCoordinator(environment: world.environment)

        let outcomes = await finished(within: 30) { () -> [AutomaticSyncOutcome] in
            let first = Task { await coordinator.runAutomatic(.observer) }
            await world.syncLatch.waitForArrivals(1)
            let others = [SyncTrigger.foreground, .appRefresh, .unlock].map { trigger in
                Task { await coordinator.runAutomatic(trigger) }
            }
            while await coordinator.waiting < 3 { await Task.yield() }
            await world.syncLatch.open()
            var outcomes = [await first.value]
            for other in others { outcomes.append(await other.value) }
            return outcomes
        }

        XCTAssertEqual(outcomes, [.ran(success: true), .notDue, .notDue, .notDue])
        XCTAssertEqual(world.incrementals, 1)
    }

    func testSyncNowWaitsForARunningSyncAndIgnoresTheSchedule() async {
        let world = World()
        await world.drainLatch.open()
        world.schedule = SyncSchedule(quietWindow: QuietWindow(from: TimeOfDay(hour: 9, minute: 0), to: TimeOfDay(hour: 11, minute: 0)))
        world.state.lastRun = nil
        let coordinator = SyncCoordinator(environment: world.environment)

        // Quiet hours: nothing automatic runs, but Sync Now does, and records nothing.
        let automatic = await coordinator.runAutomatic(.observer)
        XCTAssertEqual(automatic, .notDue)
        await world.syncLatch.open()
        _ = await coordinator.runManual(full: true)
        XCTAssertEqual(world.fulls, 1)
        XCTAssertNil(world.state.lastRun)
    }

    func testAManualSyncQueuesBehindAnAutomaticOne() async {
        let world = World()
        await world.drainLatch.open()
        let coordinator = SyncCoordinator(environment: world.environment)

        let returned = await finished(within: 30) { () -> Bool in
            let automatic = Task { await coordinator.runAutomatic(.observer) }
            await world.syncLatch.waitForArrivals(1)
            let manual = Task { await coordinator.runManual(full: false) }
            while await coordinator.waiting < 1 { await Task.yield() }
            XCTAssertEqual(world.incrementals, 1, "the manual sync must wait")

            await world.syncLatch.open()
            _ = await automatic.value
            _ = await manual.value
            return true
        }

        XCTAssertNotNil(returned, "the manual sync never returned")
        XCTAssertEqual(world.incrementals, 2)
    }

    /// How far a test got, for the message when its watchdog fires.
    private final class Step: @unchecked Sendable {
        private let lock = NSLock()
        private var _name = "the run starts"
        var name: String { lock.withLock { _name } }
        func set(_ name: String) { lock.withLock { _name = name } }
    }

    /// Runs `work` under a watchdog and gives its result, or nil when it did not finish in time.
    /// A spin never suspends, so only a clock can tell it from a long wait; the limit is far
    /// above what a passing run takes and only decides how a broken one fails.
    private func finished<T: Sendable>(within seconds: TimeInterval, _ work: @escaping @Sendable () async -> T) async -> T? {
        let run = Task { await work() }
        let done = expectation(description: "finished")
        Task { _ = await run.value; done.fulfill() }
        guard await XCTWaiter().fulfillment(of: [done], timeout: seconds) == .completed else { return nil }
        return await run.value
    }

    /// Starts an automatic run whose first step already runs on the coordinator, so the test
    /// does not wait for a thread of the run's priority to pick it up. The executor learns
    /// which task it is.
    private static func startAutomatic(
        on coordinator: isolated SyncCoordinator, priority: TaskPriority, executor: HoldingExecutor
    ) -> Task<AutomaticSyncOutcome, Never> {
        executor.watchNextTask()
        return Task(priority: priority) {
            coordinator.preconditionIsolated()
            return await coordinator.runAutomatic(.observer)
        }
    }

    /// Sync Now can get the actor after a run has ended but before the run's owner is back, as
    /// when the owner is a HealthKit wakeup of lower priority. It must find the run gone and do
    /// its one full sync after it, not await the finished run again and again while the owner
    /// never gets in. The owner is held out of the actor until Sync Now has returned, so that
    /// order is certain instead of left to the scheduler; with the flight cleared by its owner,
    /// as before ecf84a9, this spins every time.
    func testAManualSyncOfHigherPriorityNeverSpinsOnAFinishedFlight() async {
        let world = World()
        await world.drainLatch.open()
        let executor = HoldingExecutor()
        let coordinator = SyncCoordinator(environment: world.environment, executor: executor)
        let step = Step()

        let owner = await finished(within: 30) { () -> AutomaticSyncOutcome in
            let run = await Self.startAutomatic(on: coordinator, priority: .utility, executor: executor)
            await world.syncLatch.waitForArrivals(1)
            executor.hold()
            step.set("Sync Now queues")
            let manual = Task(priority: .userInitiated) { await coordinator.runManual(full: true) }
            while await coordinator.waiting < 1 { await Task.yield() }
            step.set("Sync Now returns")
            await world.syncLatch.open()
            _ = await manual.value
            XCTAssertEqual(world.fulls, 1)
            // The owner was out all along: its way back in is the one job held.
            step.set("the owner is back at the actor")
            await executor.held(1)
            XCTAssertEqual(executor.release(), 1)
            step.set("the owner returns")
            return await run.value
        }

        guard let owner else {
            XCTFail("Stuck until: \(step.name)")
            return
        }
        XCTAssertEqual(owner, .ran(success: true))
        XCTAssertEqual(world.events, ["drain", "incremental", "incremental done", "drain", "full", "full done"])
    }

    /// Sync Now pressed while a run is in progress is never folded into it: every request that
    /// waited does its own full sync, one after the other.
    func testEverySyncNowThatWaitedDoesItsOwnFullSync() async {
        let world = World()
        await world.drainLatch.open()
        let coordinator = SyncCoordinator(environment: world.environment)

        let outcome = await finished(within: 30) { () -> AutomaticSyncOutcome in
            let automatic = Task { await coordinator.runAutomatic(.observer) }
            await world.syncLatch.waitForArrivals(1)
            let manuals = (0..<3).map { _ in Task { await coordinator.runManual(full: true) } }
            while await coordinator.waiting < 3 { await Task.yield() }
            await world.syncLatch.open()
            for manual in manuals { _ = await manual.value }
            return await automatic.value
        }

        XCTAssertEqual(outcome, .ran(success: true))
        XCTAssertEqual(world.fulls, 3)
        let oneFull = ["drain", "full", "full done"]
        XCTAssertEqual(world.events, ["drain", "incremental", "incremental done"] + oneFull + oneFull + oneFull)
    }

    func testAutomaticRetriesWaitForQuietHoursAndRetryNowDoesNot() async {
        let world = await openWorld()
        world.schedule = SyncSchedule(quietWindow: QuietWindow(from: TimeOfDay(hour: 9, minute: 0), to: TimeOfDay(hour: 11, minute: 0)))
        let coordinator = SyncCoordinator(environment: world.environment)

        await coordinator.drain(automatic: true)
        XCTAssertEqual(world.drains, 0)
        await coordinator.drain(automatic: false)
        XCTAssertEqual(world.drains, 1)
    }

    func testARunStoppedBeforeTheReadLeavesTheSyncOwed() async {
        let world = World()
        await world.syncLatch.open()
        // Cancelled before the coordinator waits on its work, the run passes the cancellation
        // on only once the coordinator gets there; the drain lets go after that.
        let workCancelled = Latch()
        var environment = world.environment
        environment.drain = {
            world.addDrain()
            await withTaskCancellationHandler {
                await world.drainLatch.wait()
            } onCancel: {
                Task { await workCancelled.open() }
            }
        }
        let coordinator = SyncCoordinator(environment: environment)

        let outcome = await finished(within: 30) { () -> AutomaticSyncOutcome in
            let run = Task { await coordinator.runAutomatic(.appRefresh) }
            await world.drainLatch.waitForArrivals(1)
            run.cancel()
            await workCancelled.wait()
            await world.drainLatch.open()
            return await run.value
        }

        XCTAssertEqual(outcome, .cancelled)
        XCTAssertEqual(world.incrementals, 0)
        XCTAssertNil(world.state.lastRun)
    }
}

/// Where a sync may go. MQTT alone is a destination, as on Android: Sync Now, the observers,
/// the background tasks and every automatic sync ask `healthSyncConfigured`.
final class SyncDestinationTests: XCTestCase {
    private func makePrefs() -> PreferencesManager {
        let name = "sync-destination-tests-\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        let prefs = PreferencesManager(defaults: UserDefaults(suiteName: name)!, secrets: InMemorySecretStore())
        prefs.healthEnabledDataTypes = [.steps, .heartRate]
        return prefs
    }

    func testABrokerWithoutAWebhookIsADestination() {
        let prefs = makePrefs()
        XCTAssertFalse(prefs.healthSyncConfigured)

        prefs.mqttEnabled = true
        prefs.mqttHost = "homeassistant.local"

        XCTAssertTrue(prefs.healthWebhookUrls.isEmpty)
        XCTAssertTrue(prefs.mqttConfigured)
        XCTAssertTrue(prefs.hasHealthDestination)
        XCTAssertTrue(prefs.healthSyncConfigured)
    }

    func testABrokerNeedsTheSwitchAndAHost() {
        let prefs = makePrefs()
        prefs.mqttHost = "homeassistant.local"
        XCTAssertFalse(prefs.healthSyncConfigured, "switched off")

        prefs.mqttEnabled = true
        prefs.mqttHost = "   "
        XCTAssertFalse(prefs.mqttConfigured, "blank host")
        XCTAssertFalse(prefs.healthSyncConfigured)
    }

    func testAWebhookAloneStillCounts() {
        let prefs = makePrefs()
        prefs.healthWebhookUrls = ["https://example.com/health"]
        XCTAssertFalse(prefs.mqttConfigured)
        XCTAssertTrue(prefs.healthSyncConfigured)
    }

    func testNothingToReadIsNotConfiguredWhateverTheDestination() {
        let prefs = makePrefs()
        prefs.healthWebhookUrls = ["https://example.com/health"]
        prefs.mqttEnabled = true
        prefs.mqttHost = "homeassistant.local"
        prefs.healthEnabledDataTypes = []
        XCTAssertTrue(prefs.hasHealthDestination)
        XCTAssertFalse(prefs.healthSyncConfigured)
    }

    /// The background sync manager starts the observers on this, so a broker added after launch
    /// syncs without a relaunch.
    func testAChangedDestinationIsAnnounced() {
        let prefs = makePrefs()
        var posts = 0
        let token = NotificationCenter.default.addObserver(
            forName: .healthDestinationsDidChange, object: prefs, queue: nil
        ) { _ in posts += 1 }
        defer { NotificationCenter.default.removeObserver(token) }

        prefs.mqttEnabled = true
        prefs.mqttHost = "homeassistant.local"
        prefs.healthWebhookUrls = ["https://example.com/health"]
        XCTAssertEqual(posts, 3)

        prefs.mqttEnabled = true
        prefs.mqttHost = "homeassistant.local"
        prefs.healthWebhookUrls = ["https://example.com/health"]
        prefs.mqttPort = 8883
        XCTAssertEqual(posts, 3, "the same value again, or a setting that is not a destination")
    }
}
