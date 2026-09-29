import XCTest
@testable import LifeDashboardCompanion

final class SingleFlightTests: XCTestCase {

    private actor Counter {
        private(set) var runs = 0
        private(set) var concurrent = 0
        private(set) var maxConcurrent = 0
        private(set) var sawCancellation = false

        func start() {
            runs += 1
            concurrent += 1
            maxConcurrent = max(maxConcurrent, concurrent)
        }

        func end(cancelled: Bool) {
            concurrent -= 1
            if cancelled { sawCancellation = true }
        }
    }

    private func work(_ counter: Counter, _ latch: Latch) -> @Sendable () async -> Void {
        {
            await counter.start()
            await latch.wait()
            await counter.end(cancelled: Task.isCancelled)
        }
    }

    func testCallersThatArriveDuringARunWaitForItAndItRunsOnceMore() async {
        let flight = SingleFlight<Never>()
        let counter = Counter()
        let latch = Latch()
        let work = work(counter, latch)

        let owner = Task { await flight.run(work) }
        let started = await settle { await counter.runs == 1 }
        XCTAssertTrue(started)

        let joiners = (0..<5).map { _ in Task { await flight.run(work) } }
        // Give every joiner the chance to reach the flight before the run ends.
        for _ in 0..<200 { await Task.yield() }
        await latch.open()

        let ownerRan = await owner.value
        var joinerRan: [Bool] = []
        for joiner in joiners { joinerRan.append(await joiner.value) }

        let runs = await counter.runs
        let maxConcurrent = await counter.maxConcurrent
        XCTAssertTrue(ownerRan)
        XCTAssertEqual(joinerRan, Array(repeating: false, count: 5))
        // One run for all six callers, plus the single rerun their arrival asked for.
        XCTAssertEqual(runs, 2)
        XCTAssertEqual(maxConcurrent, 1)
    }

    func testARunAfterTheLastOneFinishedRunsAgain() async {
        let flight = SingleFlight<Never>()
        let counter = Counter()
        let latch = Latch()
        await latch.open()

        let first = await flight.run(work(counter, latch))
        let second = await flight.run(work(counter, latch))

        let runs = await counter.runs
        XCTAssertTrue(first)
        XCTAssertTrue(second)
        XCTAssertEqual(runs, 2)
    }

    func testCancellingTheCallerThatStartedTheWorkCancelsTheWork() async {
        let flight = SingleFlight<Never>()
        let counter = Counter()
        let latch = Latch()

        let job = work(counter, latch)
        let owner = Task { await flight.run(job) }
        _ = await settle { await counter.runs == 1 }
        owner.cancel()
        await latch.open()
        _ = await owner.value

        let sawCancellation = await counter.sawCancellation
        XCTAssertTrue(sawCancellation)
    }

    // MARK: - Handing over (the incremental sync)

    func testFirstCallerRunsAndALaterOneHandsOver() async {
        let gate = SingleFlight<String>()
        let first = await gate.enter(["steps"])
        let second = await gate.enter(["heart_rate"])
        XCTAssertTrue(first)
        XCTAssertFalse(second)
    }

    func testTheRunningCallerGetsWhatWasHandedOverOnce() async {
        let gate = SingleFlight<String>()
        _ = await gate.enter(["steps"])
        _ = await gate.enter(["heart_rate"])
        _ = await gate.enter(["heart_rate", "sleep"])
        let round = await gate.next()
        XCTAssertEqual(round, ["heart_rate", "sleep"])
        let after = await gate.next()
        XCTAssertNil(after)
    }

    func testAFinishedRunLetsTheNextCallerIn() async {
        let gate = SingleFlight<String>()
        _ = await gate.enter(["steps"])
        _ = await gate.next()
        let again = await gate.enter(["steps"])
        XCTAssertTrue(again)
    }

    func testTypesHandedOverDuringTheExtraRoundGetAnotherOne() async {
        let gate = SingleFlight<String>()
        _ = await gate.enter(["steps"])
        _ = await gate.enter(["sleep"])
        _ = await gate.next()
        let late = await gate.enter(["weight"])
        XCTAssertFalse(late)
        let round = await gate.next()
        XCTAssertEqual(round, ["weight"])
    }

    func testResultsOfRoundsCombine() {
        let one = HealthSyncResult.success(syncCounts: [.steps: 3])
        let two = HealthSyncResult.success(syncCounts: [.steps: 2, .sleep: 1])
        guard case .success(let counts) = one.merged(with: two) else { return XCTFail("expected success") }
        XCTAssertEqual(counts, [.steps: 5, .sleep: 1])
        guard case .failure = one.merged(with: .failure(error: "down")) else { return XCTFail("expected failure") }
        guard case .success = HealthSyncResult.noData.merged(with: one) else { return XCTFail("expected success") }
    }
}
