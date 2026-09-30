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

    // MARK: - Added samples

    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    private func added(_ id: Int, hours start: Double, _ end: Double? = nil) -> AddedSample {
        AddedSample(
            uuid: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", id))!,
            start: base.addingTimeInterval(start * 3600),
            end: base.addingTimeInterval((end ?? start) * 3600)
        )
    }

    func testAPageNeverHoldsMoreThanOnePayloadCarries() {
        XCTAssertEqual(IncrementalRead.pageLimit(for: .heartRate, sampleTypeCount: 1), 1000)
        XCTAssertEqual(IncrementalRead.pageLimit(for: .totalCalories, sampleTypeCount: 2), 100)
        XCTAssertEqual(IncrementalRead.pageLimit(for: .nutrition, sampleTypeCount: 300), 1)
        // The first week takes nine tenths of the cap; the page gets the tenth left.
        XCTAssertEqual(IncrementalRead.pageLimit(for: .heartRate, sampleTypeCount: 1, catchingUp: true), 100)
    }

    func testAddedSamplesTheTimeReadCoversAreNotReadTwice() {
        let samples = [added(1, hours: -200), added(2, hours: -10), added(3, hours: 5)]
        let now = base

        XCTAssertEqual(IncrementalRead.byUuid(samples, timeReadFrom: nil, now: now), samples)
        // From -24 h on the time read reaches everything up to now; the future one it never does.
        XCTAssertEqual(
            IncrementalRead.byUuid(samples, timeReadFrom: base.addingTimeInterval(-24 * 3600), now: now).map(\.uuid),
            [samples[0].uuid, samples[2].uuid]
        )
        let plan = IncrementalRead.plan(cursor: base.addingTimeInterval(-24 * 3600), firstRead: nil, added: samples, now: now)
        XCTAssertEqual(plan.timeReadStart, base.addingTimeInterval(-24 * 3600))
        XCTAssertEqual(plan.byUuid.map(\.uuid), [samples[0].uuid, samples[2].uuid])
        XCTAssertEqual(SyncLimits.timeReadStart(cursor: nil, firstRead: nil), nil)
        XCTAssertEqual(SyncLimits.timeReadStart(cursor: base, firstRead: base.addingTimeInterval(-60)), base.addingTimeInterval(-60))
    }

    func testSessionWindowsSurroundEachNightWithoutJoiningNights() {
        // Two stages of one night and one stage of a night a year earlier.
        let windows = IncrementalRead.sessionWindows(
            for: [added(1, hours: 1, 2), added(2, hours: 2.5, 4), added(3, hours: -8760, -8759)],
            gap: 3600, padding: 86_400
        )
        XCTAssertEqual(windows, [
            DateInterval(start: base.addingTimeInterval(-8760 * 3600 - 86_400), end: base.addingTimeInterval(-8759 * 3600 + 86_400)),
            DateInterval(start: base.addingTimeInterval(3600 - 86_400), end: base.addingTimeInterval(4 * 3600 + 86_400))
        ])
        // A stage every 20 hours for a week is seven groups, however the padding overlaps.
        let spread = (0..<7).map { added($0, hours: Double($0) * 20) }
        XCTAssertEqual(IncrementalRead.sessionWindows(for: spread, gap: 3600, padding: 86_400).count, 7)
    }

    func testOnlySessionsAndPeriodsHoldingAnAddedSampleAreSent() {
        let new = added(7, hours: 3)
        let stage: (Int) -> [String: Any] = { ["uuid": UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", $0))!.uuidString] }
        let sessions: [[String: Any]] = [
            ["uuid": "night-a", "stages": [stage(5), stage(6)]],
            ["uuid": "night-b", "stages": [stage(6), stage(7)]]
        ]
        XCTAssertEqual(IncrementalRead.sessions(sessions, holding: [new.uuid]).map { $0["uuid"] as? String }, ["night-b"])

        let periods: [[String: Any]] = [
            ["start_time": base.iso8601String, "end_time": base.addingTimeInterval(2 * 3600).iso8601String],
            ["start_time": base.addingTimeInterval(2.5 * 3600).iso8601String, "end_time": base.addingTimeInterval(9 * 3600).iso8601String]
        ]
        XCTAssertEqual(IncrementalRead.periods(periods, holding: [new]).count, 1)
        // A flow day at the very end of a period, with a fraction of a second the period's
        // whole-second end has lost.
        let lastDay = AddedSample(uuid: UUID(), start: base.addingTimeInterval(9 * 3600 + 0.4), end: base.addingTimeInterval(9 * 3600 + 0.4))
        XCTAssertEqual(IncrementalRead.periods(periods, holding: [lastDay]).count, 1)
        XCTAssertEqual(IncrementalRead.periods(periods, holding: [new]).first?["end_time"] as? String, base.addingTimeInterval(9 * 3600).iso8601String)
    }

    func testTheTimeReadAndTheUuidReadSendEachRecordOnce() throws {
        let merged = try XCTUnwrap(IncrementalRead.merge(
            [("weight", [["uuid": "a", "kilograms": 70.0], ["uuid": "b", "kilograms": 71.0]] as [[String: Any]])],
            [("weight", [["uuid": "b", "kilograms": 71.0], ["uuid": "c", "kilograms": 72.0]] as [[String: Any]]),
             ("menstruation_period", [["start_time": "x", "end_time": "y"], ["start_time": "x", "end_time": "y"]] as [[String: Any]])]
        ))
        let byKey = Dictionary(uniqueKeysWithValues: merged.map { ($0.0, ($0.1 as? [[String: Any]])?.count ?? 0) })
        XCTAssertEqual(byKey, ["weight": 3, "menstruation_period": 1])
        XCTAssertNil(IncrementalRead.merge(nil, nil))
    }

    func testMqttGetsATypeOnlyWhenItsNewestSampleIsInTheRead() {
        let today = base
        let lastYear = base.addingTimeInterval(-365 * 86_400)
        // A weight entered for last year, while HealthKit holds one from today.
        let now = base.addingTimeInterval(60)
        XCTAssertFalse(IncrementalRead.holdsNewest(behind: false, timeReadReachedNow: false, byUuidStarts: [lastYear], newestInStore: today, now: now))
        XCTAssertTrue(IncrementalRead.holdsNewest(behind: false, timeReadReachedNow: false, byUuidStarts: [lastYear, today], newestInStore: today, now: now))
        XCTAssertTrue(IncrementalRead.holdsNewest(behind: false, timeReadReachedNow: true, byUuidStarts: [], newestInStore: today, now: now))
        XCTAssertFalse(IncrementalRead.holdsNewest(behind: true, timeReadReachedNow: true, byUuidStarts: [today], newestInStore: today, now: now))
        // A weight dated next year is no current value.
        let nextYear = base.addingTimeInterval(365 * 86_400)
        XCTAssertFalse(IncrementalRead.holdsNewest(behind: false, timeReadReachedNow: false, byUuidStarts: [nextYear], newestInStore: today, now: now))
        // A probe that failed says nothing is known to be newest.
        XCTAssertFalse(IncrementalRead.holdsNewest(behind: false, timeReadReachedNow: false, byUuidStarts: [today], newestInStore: .distantFuture, now: now))
    }
}

/// Collects values from any thread.
final class Recorder<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Value] = []

    var items: [Value] { lock.withLock { values } }

    func add(_ value: Value) { lock.withLock { values.append(value) } }
}
