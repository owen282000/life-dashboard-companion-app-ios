import XCTest
@testable import LifeDashboardCompanion

final class HealthReadTests: XCTestCase {

    // MARK: - One type at a time

    private struct Stuck: Error {}

    /// A HealthKit query that never answers: only the deadline ends it.
    private final class Hanging: @unchecked Sendable {
        private let lock = NSLock()
        private var deadline: (@Sendable () -> Void)?
        private(set) var stops = 0

        var schedule: BoundedCall.Scheduler {
            { _, work in self.lock.withLock { self.deadline = work } }
        }

        var armed: Bool { lock.withLock { deadline != nil } }

        func expire() {
            let work = lock.withLock { deadline }
            work?()
        }

        func read() async throws -> [(String, Any)]? {
            try await BoundedCall.run(timeout: .seconds(10), schedule: schedule) { _ in
                { self.lock.withLock { self.stops += 1 } }
            }
        }
    }

    func testATypeWhoseQueryDoesNotAnswerFailsAloneAndTheOthersGoAhead() async {
        let hanging = Hanging()
        let failures = Recorder<HealthDataType>()
        let task = Task {
            await HealthKitManager.gather([.steps, .heartRate, .weight]) { type -> [(String, Any)]? in
                switch type {
                case .heartRate: return try await hanging.read()
                case .weight: throw Stuck()
                default: return [("steps", [["count": 12]])]
                }
            } failed: { type, _ in
                failures.add(type)
            }
        }
        let armed = await settle { hanging.armed }
        XCTAssertTrue(armed)
        hanging.expire()

        let fragments = await task.value
        XCTAssertEqual(Set(fragments.keys), [.steps])
        XCTAssertEqual(Set(failures.items), [.heartRate, .weight])
        XCTAssertEqual(hanging.stops, 1, "the query that ran out of time is stopped")
        let payload = HealthKitManager.merge(fragments.values)
        XCTAssertEqual((payload["steps"] as? [[String: Int]])?.first?["count"], 12)
    }

    func testATypeWithNothingToSendIsNotAFailure() async {
        let failures = Recorder<HealthDataType>()
        let fragments = await HealthKitManager.gather([.steps, .weight]) { type -> [(String, Any)]? in
            type == .steps ? nil : [("weight", [["kilograms": 70.0]])]
        } failed: { type, _ in
            failures.add(type)
        }
        XCTAssertEqual(Set(fragments.keys), [.weight])
        XCTAssertTrue(failures.items.isEmpty)
    }
}

/// Collects values from any thread.
final class Recorder<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Value] = []

    var items: [Value] { lock.withLock { values } }

    func add(_ value: Value) { lock.withLock { values.append(value) } }
}
