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
        let syncLatch = Latch()
        let drainLatch = Latch()

        var now: Date { get { lock.withLock { _now } } set { lock.withLock { _now = newValue } } }
        var unlocked: Bool { get { lock.withLock { _unlocked } } set { lock.withLock { _unlocked = newValue } } }
        var schedule: SyncSchedule { get { lock.withLock { _schedule } } set { lock.withLock { _schedule = newValue } } }
        var state: ScheduleState { get { lock.withLock { _state } } set { lock.withLock { _state = newValue } } }
        var result: HealthSyncResult { get { lock.withLock { _result } } set { lock.withLock { _result = newValue } } }

        func count(_ body: (World) -> Void) { lock.withLock { body(self) } }
        func addDrain() { lock.withLock { drains += 1 } }
        func addIncremental() { lock.withLock { incrementals += 1 } }
        func addFull() { lock.withLock { fulls += 1 } }
        func addReplan(_ locked: Bool) { lock.withLock { replans.append(locked) } }

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
                    return self.result
                },
                syncFull: {
                    self.addFull()
                    await self.syncLatch.wait()
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
