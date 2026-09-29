import XCTest
@testable import LifeDashboardCompanion

final class SingleFlightTests: XCTestCase {

    private actor Counter {
        private(set) var runs = 0
        private(set) var concurrent = 0
        private(set) var maxConcurrent = 0

        func start() {
            runs += 1
            concurrent += 1
            maxConcurrent = max(maxConcurrent, concurrent)
        }

        func end() { concurrent -= 1 }
    }

    func testCallersThatArriveDuringARunWaitForItInsteadOfStartingAnother() async {
        let flight = SingleFlight()
        let counter = Counter()
        let work: @Sendable () async -> Void = {
            await counter.start()
            try? await Task.sleep(nanoseconds: 200_000_000)
            await counter.end()
        }

        let ran = await withTaskGroup(of: Bool.self) { group -> [Bool] in
            for _ in 0..<6 {
                group.addTask { await flight.run(work) }
            }
            var results: [Bool] = []
            for await result in group { results.append(result) }
            return results
        }

        let runs = await counter.runs
        let maxConcurrent = await counter.maxConcurrent
        XCTAssertEqual(runs, 1)
        XCTAssertEqual(maxConcurrent, 1)
        XCTAssertEqual(ran.filter { $0 }.count, 1)
    }

    func testARunAfterTheLastOneFinishedRunsAgain() async {
        let flight = SingleFlight()
        let counter = Counter()
        let work: @Sendable () async -> Void = {
            await counter.start()
            await counter.end()
        }

        let first = await flight.run(work)
        let second = await flight.run(work)

        let runs = await counter.runs
        XCTAssertTrue(first)
        XCTAssertTrue(second)
        XCTAssertEqual(runs, 2)
    }
}
