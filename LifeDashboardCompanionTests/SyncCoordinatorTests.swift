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

        let first = Task { await coordinator.runAutomatic(.observer) }
        _ = await settle { world.incrementals == 1 }
        let others = [SyncTrigger.foreground, .appRefresh, .unlock].map { trigger in
            Task { await coordinator.runAutomatic(trigger) }
        }
        for _ in 0..<200 { await Task.yield() }
        await world.syncLatch.open()

        let firstOutcome = await first.value
        var otherOutcomes: [AutomaticSyncOutcome] = []
        for other in others { otherOutcomes.append(await other.value) }
        XCTAssertEqual(firstOutcome, .ran(success: true))
        XCTAssertEqual(otherOutcomes, [.notDue, .notDue, .notDue])
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

        let automatic = Task { await coordinator.runAutomatic(.observer) }
        _ = await settle { world.incrementals == 1 }
        let manual = Task { await coordinator.runManual(full: false) }
        for _ in 0..<200 { await Task.yield() }
        XCTAssertEqual(world.incrementals, 1, "the manual sync must wait")

        await world.syncLatch.open()
        _ = await automatic.value
        _ = await manual.value
        XCTAssertEqual(world.incrementals, 2)
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

    /// Sync Now from the main thread outranks a HealthKit wakeup at background priority whose
    /// run is in progress. When that run ends, Sync Now can get the actor before the run's owner
    /// does; it must find the run gone and do its one full sync after it, not await the finished
    /// run again and again while the owner never gets in. Every step waits for the one before
    /// instead of for a number of turns, so a slow machine makes the test slower, not red.
    func testAManualSyncOfHigherPriorityNeverSpinsOnAFinishedFlight() async {
        // All owners start at once: a task at background priority can wait long for a CPU, and
        // forty such waits in a row would add up.
        let worlds = (0..<40).map { _ in World() }
        var coordinators: [SyncCoordinator] = []
        var owners: [Task<AutomaticSyncOutcome, Never>] = []
        for world in worlds {
            await world.drainLatch.open()
            let coordinator = SyncCoordinator(environment: world.environment)
            coordinators.append(coordinator)
            owners.append(Task(priority: .background) { await coordinator.runAutomatic(.observer) })
        }

        for (world, coordinator) in zip(worlds, coordinators) {
            let returned = await finished(within: 30) {
                await world.syncLatch.waitForArrivals(1)
                let manual = Task(priority: .userInitiated) { await coordinator.runManual(full: true) }
                while await coordinator.waiting < 1 { await Task.yield() }
                await world.syncLatch.open()
                return await manual.value
            }
            guard returned != nil else {
                XCTFail("Sync Now did not return: it never queued, or it spins on the finished run")
                return
            }
            XCTAssertEqual(world.events, ["drain", "incremental", "incremental done", "drain", "full", "full done"])
        }
        // The owners get back in at background priority, which may take a while.
        let owned = owners
        let outcomes = await finished(within: 300) {
            var outcomes: [AutomaticSyncOutcome] = []
            for owner in owned { outcomes.append(await owner.value) }
            return outcomes
        }
        XCTAssertEqual(outcomes, Array(repeating: .ran(success: true), count: 40))
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
        let coordinator = SyncCoordinator(environment: world.environment)

        let run = Task { await coordinator.runAutomatic(.appRefresh) }
        _ = await settle { world.drains == 1 }
        run.cancel()
        await world.drainLatch.open()

        let outcome = await run.value
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
