import HealthKit
import XCTest
@testable import LifeDashboardCompanion

/// The deletion fields exactly as they reach a receiver. They tell a receiver to remove data it
/// already stored, so a wrong key, or a field that appears when it should not, destroys data.
final class DeletionTrackingTests: XCTestCase {

    private func record(_ type: String, _ uuid: String) -> DeletedRecord {
        DeletedRecord(type: type, uuid: uuid)
    }

    private func pending(_ type: String, _ uuid: String, generation: Int = 1) -> PendingDeletion {
        PendingDeletion(record: record(type, uuid), generation: generation)
    }

    private func json(_ fields: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
        return try XCTUnwrap(String(bytes: data, encoding: .utf8))
    }

    // MARK: - Payload fields

    func testNothingDeletedMeansNoDeletionFieldsAtAll() {
        let fields = DeletionTracking.payloadFields(DeletionSummary())
        XCTAssertTrue(fields.isEmpty)
    }

    func testDeletedRecordNamesItsCollectionAndUuidInAndroidsShape() throws {
        let summary = DeletionSummary(deleted: [record("nutrition", "84E37E8A-1C2D-4E5F-8A9B-0C1D2E3F4A5B")])
        XCTAssertEqual(
            try json(DeletionTracking.payloadFields(summary)),
            #"{"deleted_records":[{"type":"nutrition","uuid":"84E37E8A-1C2D-4E5F-8A9B-0C1D2E3F4A5B"}]}"#
        )
    }

    func testAnUnavailableTypeIsNamedWithoutPretendingToKnowItsDeletions() throws {
        let summary = DeletionSummary(unavailableTypes: ["heart_rate", "nutrition"])
        XCTAssertEqual(
            try json(DeletionTracking.payloadFields(summary)),
            #"{"deletions_unavailable":["heart_rate","nutrition"]}"#
        )
    }

    // MARK: - Plan

    func testPlanSortsByTypeThenUuidAndDropsDuplicates() {
        let plan = DeletionTracking.plan(
            pending: [pending("weight", "B"), pending("nutrition", "Z"), pending("weight", "A"), pending("weight", "B", generation: 2)],
            unavailable: [:],
            readIds: [:],
            readGeneration: 5
        )
        XCTAssertEqual(plan.summary.deleted, [record("nutrition", "Z"), record("weight", "A"), record("weight", "B")])
        XCTAssertEqual(plan.carried.deletions.count, 4, "Both copies of a duplicate leave the store with the payload")
    }

    func testTheSameUuidUnderTwoKeysStaysTwoEntries() {
        // An active energy sample is part of both calorie types.
        let plan = DeletionTracking.plan(
            pending: [pending("total_calories", "E"), pending("active_calories", "E")],
            unavailable: [:],
            readIds: [:],
            readGeneration: 1
        )
        XCTAssertEqual(plan.summary.deleted, [record("active_calories", "E"), record("total_calories", "E")])
    }

    func testAUuidReadAfterItsDeletionIsStaleAndDropped() {
        let plan = DeletionTracking.plan(
            pending: [pending("weight", "A", generation: 3), pending("weight", "B", generation: 3)],
            unavailable: [:],
            readIds: ["weight": ["A"]],
            readGeneration: 3
        )
        XCTAssertEqual(plan.summary.deleted, [record("weight", "B")])
        XCTAssertEqual(plan.stale, [pending("weight", "A", generation: 3)])
    }

    func testAUuidCommittedDuringTheReadIsWithheldButKept() {
        // Another sync stored the deletion while this one read the record: this payload does not
        // name it, and it stays for the next one.
        let plan = DeletionTracking.plan(
            pending: [pending("weight", "A", generation: 4)],
            unavailable: [:],
            readIds: ["weight": ["A"]],
            readGeneration: 3
        )
        XCTAssertTrue(plan.summary.deleted.isEmpty)
        XCTAssertTrue(plan.stale.isEmpty)
        XCTAssertTrue(plan.carried.deletions.isEmpty)
    }

    func testAUuidReadUnderAnotherKeyDoesNotCount() {
        let plan = DeletionTracking.plan(
            pending: [pending("weight", "A")],
            unavailable: [:],
            readIds: ["active_calories": ["A"]],
            readGeneration: 1
        )
        XCTAssertEqual(plan.summary.deleted, [record("weight", "A")])
    }

    func testAPayloadCarriesAtMostTheLimitAndTheRestWaits() {
        let many = (0..<12_000).map { pending("heart_rate", String(format: "%05d", $0)) }
        let plan = DeletionTracking.plan(pending: many, unavailable: [:], readIds: [:], readGeneration: 1)
        XCTAssertEqual(plan.summary.deleted.count, DeletionTracking.maxDeletedPerPayload)
        XCTAssertEqual(plan.summary.deleted.first?.uuid, "00000")
        XCTAssertEqual(plan.carried.deletions.count, DeletionTracking.maxDeletedPerPayload)
    }

    func testUnavailableTypesAreSortedAndCarriedWithTheirGeneration() {
        let plan = DeletionTracking.plan(
            pending: [],
            unavailable: ["weight": 2, "heart_rate": 7],
            readIds: [:],
            readGeneration: 1
        )
        XCTAssertEqual(plan.summary.unavailableTypes, ["heart_rate", "weight"])
        XCTAssertEqual(plan.carried.unavailable, ["weight": 2, "heart_rate": 7])
    }

    // MARK: - Read ids

    func testRecordUuidsIncludeSleepStages() {
        let payload: [String: Any] = [
            "weight": [["uuid": "W1", "kilograms": 70.0]],
            "sleep": [["session_end_time": "x", "stages": [["uuid": "S1"], ["uuid": "S2"]]]],
            "timestamp": "2026-09-30T00:00:00Z"
        ]
        XCTAssertEqual(DeletionTracking.recordUUIDs(in: payload), ["weight": ["W1"], "sleep": ["S1", "S2"]])
    }

    // MARK: - Budgets and age

    func testTimeouts() {
        let total = DeletionTracking.foregroundBudget
        XCTAssertEqual(DeletionTracking.timeoutFor(elapsed: .zero, total: total), .seconds(5))
        XCTAssertEqual(DeletionTracking.timeoutFor(elapsed: .seconds(17), total: total), .seconds(3))
        XCTAssertEqual(DeletionTracking.timeoutFor(elapsed: .seconds(20), total: total), .zero)
        XCTAssertEqual(DeletionTracking.timeoutFor(elapsed: .seconds(25), total: total), .zero)
        XCTAssertEqual(DeletionTracking.timeoutFor(elapsed: .seconds(5), total: DeletionTracking.backgroundBudget), .seconds(3))
    }

    func testStaleness() {
        let now = Date(timeIntervalSince1970: 1_000_000_000)
        XCTAssertFalse(DeletionTracking.isStale(lastCompleteReadAt: nil, now: now), "A start is not a gap")
        XCTAssertFalse(DeletionTracking.isStale(lastCompleteReadAt: now.addingTimeInterval(-6.9 * 86_400), now: now))
        XCTAssertTrue(DeletionTracking.isStale(lastCompleteReadAt: now.addingTimeInterval(-7 * 86_400), now: now))
        XCTAssertTrue(DeletionTracking.isStale(lastCompleteReadAt: now.addingTimeInterval(60), now: now))
    }

    // MARK: - Mapping

    func testEveryTypeHasItsOwnDeletionKey() {
        let keys = HealthDataType.allCases.map(\.deletionPayloadKey)
        XCTAssertEqual(Set(keys).count, keys.count)
        XCTAssertFalse(keys.contains("menstruation_period"))
        XCTAssertEqual(HealthDataType.menstruation.deletionPayloadKey, "menstruation_flow")
        for type in HealthDataType.allCases {
            XCTAssertFalse(type.deletionSampleTypes.isEmpty, "\(type) reads no deletions")
        }
    }

    func testComponentsWhoseUuidNeverReachesThePayloadAreNotRead() {
        let identifiers = HealthDataType.allCases.flatMap(\.deletionSampleTypes).map(\.identifier)
        XCTAssertFalse(identifiers.contains(HKQuantityType(.bloodPressureDiastolic).identifier))
        XCTAssertFalse(identifiers.contains(HKQuantityType(.dietaryCarbohydrates).identifier))
        XCTAssertFalse(identifiers.contains(HKQuantityType(.dietaryFatTotal).identifier))
        XCTAssertEqual(HealthDataType.bloodPressure.deletionSampleTypes.map(\.identifier), [HKQuantityType(.bloodPressureSystolic).identifier])
    }

    func testActiveEnergyIsReadOncePerCalorieType() {
        let targets = DeletionTracking.targets(for: [.activeCalories, .totalCalories])
        let active = HKQuantityType(.activeEnergyBurned).identifier
        XCTAssertEqual(
            targets.filter { $0.sampleTypeIdentifier == active }.map(\.payloadKey).sorted(),
            ["active_calories", "total_calories"]
        )
        XCTAssertEqual(targets.map(\.key), targets.map(\.key).sorted())
    }

    // MARK: - Bounded calls

    /// A scheduler the test fires by hand.
    private final class ManualTimer: @unchecked Sendable {
        private let lock = NSLock()
        private var work: (@Sendable () -> Void)?

        var schedule: BoundedCall.Scheduler {
            { _, work in self.lock.withLock { self.work = work } }
        }

        var armed: Bool { lock.withLock { work != nil } }

        func fire() {
            let work = lock.withLock { self.work }
            work?()
        }
    }

    private final class Call: @unchecked Sendable {
        private let lock = NSLock()
        private var finish: (@Sendable (Result<Int, Error>) -> Void)?
        private(set) var starts = 0
        private(set) var stops = 0

        func start(_ finish: @escaping @Sendable (Result<Int, Error>) -> Void) -> (@Sendable () -> Void) {
            lock.withLock {
                self.finish = finish
                starts += 1
            }
            return { self.lock.withLock { self.stops += 1 } }
        }

        func answer(_ value: Int) {
            let finish = lock.withLock { self.finish }
            finish?(.success(value))
        }
    }

    func testAnAnswerInTimeIsReturnedAndNothingIsStopped() async throws {
        let call = Call()
        let timer = ManualTimer()
        let value = try await BoundedCall.run(timeout: .seconds(5), schedule: timer.schedule) { finish in
            let stop = call.start(finish)
            call.answer(42)
            return stop
        }
        XCTAssertEqual(value, 42)
        timer.fire()
        XCTAssertEqual(call.stops, 0)
    }

    func testATimeoutStopsTheCallOnceAndALateAnswerIsDropped() async {
        let call = Call()
        let timer = ManualTimer()
        let task = Task {
            try await BoundedCall.run(timeout: .seconds(5), schedule: timer.schedule) { finish in
                call.start(finish)
            }
        }
        while !timer.armed { await Task.yield() }
        timer.fire()
        timer.fire()
        call.answer(7)
        do {
            _ = try await task.value
            XCTFail("A late answer must not come through")
        } catch {
            XCTAssertTrue(error is BoundedCall.TimedOut)
        }
        XCTAssertEqual(call.stops, 1)
    }

    func testCancellationStopsTheCall() async {
        let call = Call()
        let timer = ManualTimer()
        let task = Task {
            try await BoundedCall.run(timeout: .seconds(5), schedule: timer.schedule) { finish in
                call.start(finish)
            }
        }
        while call.starts == 0 { await Task.yield() }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected a cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(call.stops, 1)
    }

    func testAnAnswerAndATimeoutAtOnceResumeExactlyOnce() async throws {
        for _ in 0..<500 {
            let call = Call()
            let timer = ManualTimer()
            let task = Task {
                try await BoundedCall.run(timeout: .seconds(5), schedule: timer.schedule) { finish in
                    call.start(finish)
                }
            }
            while !timer.armed { await Task.yield() }
            DispatchQueue.concurrentPerform(iterations: 2) { index in
                if index == 0 { call.answer(1) } else { timer.fire() }
            }
            // One of the two wins; the test would crash on a second resume and hang on none.
            _ = try? await task.value
            XCTAssertLessThanOrEqual(call.stops, 1)
        }
    }
}
