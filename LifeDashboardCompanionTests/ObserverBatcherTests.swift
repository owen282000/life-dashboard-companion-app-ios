import XCTest
@testable import LifeDashboardCompanion

@MainActor
final class ObserverBatcherTests: XCTestCase {

    private final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Bool] = []
        var all: [Bool] { lock.withLock { values } }
        func record(_ value: Bool) { lock.withLock { values.append(value) } }
    }

    private actor Runs {
        private(set) var started = 0
        private(set) var cancelled = 0
        func start() { started += 1 }
        func sawCancel() { cancelled += 1 }
    }

    private func makeBatcher(clock: ManualClock, runs: Runs, latch: Latch) -> ObserverBatcher {
        ObserverBatcher(debounce: 5, maxWait: 10, sleep: { await clock.sleep($0) }, run: {
            await runs.start()
            await latch.wait()
            if Task.isCancelled { await runs.sawCancel() }
        })
    }

    private func completion(_ calls: Calls) -> OnceCallback {
        OnceCallback { calls.record($0) }
    }

    func testWakeupsWithinTheDebounceBecomeOneSyncAndCompleteWhenItEnds() async {
        let clock = ManualClock()
        let runs = Runs()
        let latch = Latch()
        let calls = Calls()
        let batcher = makeBatcher(clock: clock, runs: runs, latch: latch)

        batcher.add(completion(calls))
        _ = await settle { await clock.waiterCount == 2 }
        await clock.advance(by: 2)
        batcher.add(completion(calls))
        _ = await settle { await clock.waiterCount == 3 }
        await clock.advance(by: 5)

        let started = await settle { await runs.started == 1 }
        XCTAssertTrue(started)
        XCTAssertTrue(calls.all.isEmpty, "HealthKit must wait until the sync has ended")

        await latch.open()
        let completed = await settle { calls.all.count == 2 }
        XCTAssertTrue(completed)
        let total = await runs.started
        XCTAssertEqual(total, 1)
    }

    func testASteadyStreamStillSyncsAtTheMaximumWait() async {
        let clock = ManualClock()
        let runs = Runs()
        let latch = Latch()
        let calls = Calls()
        let batcher = makeBatcher(clock: clock, runs: runs, latch: latch)

        batcher.add(completion(calls))
        // A wakeup every 4 seconds keeps restarting the 5 second debounce.
        for _ in 0..<2 {
            _ = await settle { await clock.waiterCount >= 2 }
            await clock.advance(by: 4)
            batcher.add(completion(calls))
        }
        _ = await settle { await clock.waiterCount >= 2 }
        await clock.advance(by: 2)

        let started = await settle { await runs.started == 1 }
        XCTAssertTrue(started, "the sync starts 10 seconds after the first wakeup")
        await latch.open()
    }

    func testAWakeupDuringARunDoesNotCancelItAndGetsATrailingSync() async {
        let clock = ManualClock()
        let runs = Runs()
        let latch = Latch()
        let calls = Calls()
        let batcher = makeBatcher(clock: clock, runs: runs, latch: latch)

        batcher.add(completion(calls))
        _ = await settle { await clock.waiterCount == 2 }
        await clock.advance(by: 5)
        _ = await settle { await runs.started == 1 }

        batcher.add(completion(calls))
        await clock.advance(by: 10)
        await latch.open()

        let second = await settle { await runs.started == 2 }
        XCTAssertTrue(second)
        let completed = await settle { calls.all.count == 2 }
        XCTAssertTrue(completed)
        let cancelled = await runs.cancelled
        XCTAssertEqual(cancelled, 0)
    }

    /// The time `now` gives, moved by the test together with the manual clock.
    private final class Wall: @unchecked Sendable {
        private let lock = NSLock()
        private var date = Date(timeIntervalSince1970: 1_800_000_000)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var now: Date { lock.withLock { date } }
        func advance(by seconds: TimeInterval) { lock.withLock { date += seconds } }
    }

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isSet: Bool { lock.withLock { value } }
        func set() { lock.withLock { value = true } }
    }

    func testTheSyncIsCancelledWhenTheFirstWakeupsBudgetIsSpent() async {
        let clock = ManualClock()
        let wall = Wall()
        let latch = Latch()
        let calls = Calls()
        let cancelled = Flag()
        let batcher = ObserverBatcher(debounce: 5, maxWait: 10, sleep: { await clock.sleep($0) }, now: { wall.now }, run: {
            await withTaskCancellationHandler {
                await latch.wait()
            } onCancel: {
                cancelled.set()
            }
        })
        func advance(_ seconds: TimeInterval) async {
            wall.advance(by: seconds)
            await clock.advance(by: seconds)
        }

        // The second wakeup came later and has more time; the first one's budget decides.
        batcher.add(completion(calls), budgetEnd: wall.start.addingTimeInterval(25))
        batcher.add(completion(calls), budgetEnd: wall.start.addingTimeInterval(30))
        // The maximum wait, and the first debounce, cancelled but still asleep, and its successor.
        _ = await settle { await clock.waiterCount == 3 }
        await advance(5)
        // Running from 5 s on: the maximum wait, and the watchdog for the 20 s left.
        let armed = await settle { await clock.waiterCount == 2 }
        XCTAssertTrue(armed)

        await advance(19.5)
        let early = await settle { cancelled.isSet }
        XCTAssertFalse(early, "half a second of the budget is left")
        await advance(0.5)
        let atBudget = await settle { cancelled.isSet }
        XCTAssertTrue(atBudget, "cut off at the budget, so a post in flight ends as interrupted")

        await latch.open()
        let completed = await settle { calls.all.count == 2 }
        XCTAssertTrue(completed)
    }

    func testACompletionRunsOnceWhicheverPathReachesItFirst() {
        let calls = Calls()
        let once = OnceCallback { calls.record($0) }
        once.call(false)
        once.call(true)
        once.call(true)
        XCTAssertEqual(calls.all, [false])
    }
}
