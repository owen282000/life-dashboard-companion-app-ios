import XCTest
@testable import LifeDashboardCompanion

final class SyncLimitsTests: XCTestCase {

    private struct Record {
        let time: Date
        let name: String
    }

    private func record(_ minute: Int) -> Record {
        Record(time: Date(timeIntervalSince1970: TimeInterval(minute * 60)), name: "r\(minute)")
    }

    func testUnderLimitIsUntouched() {
        let records = [record(3), record(1), record(2)]
        let capped = SyncLimits.capOldestFirst(records, limit: 5, timeOf: \.time)
        XCTAssertEqual(capped.map(\.name), ["r3", "r1", "r2"])
    }

    func testOverLimitKeepsOldestRecords() {
        let records = [record(5), record(1), record(4), record(2), record(3)]
        let capped = SyncLimits.capOldestFirst(records, limit: 3, timeOf: \.time)
        XCTAssertEqual(capped.map(\.name), ["r1", "r2", "r3"])
    }

    func testEveryDroppedRecordIsNewerThanEveryKeptOne() {
        let records = (1...100).shuffled().map(record)
        let capped = SyncLimits.capOldestFirst(records, limit: 40, timeOf: \.time)
        let keptMax = capped.map(\.time).max()!
        let dropped = records.filter { item in !capped.contains { $0.name == item.name } }
        XCTAssertTrue(dropped.allSatisfy { $0.time > keptMax })
    }

    func testHighVolumeTypesHaveHigherLimits() {
        XCTAssertEqual(SyncLimits.maxRecordsPerSync(for: .heartRate), 1000)
        XCTAssertEqual(SyncLimits.maxRecordsPerSync(for: .steps), 1000)
        XCTAssertEqual(SyncLimits.maxRecordsPerSync(for: .heartRateVariability), 500)
        XCTAssertEqual(SyncLimits.maxRecordsPerSync(for: .respiratoryRate), 500)
        XCTAssertEqual(SyncLimits.maxRecordsPerSync(for: .weight), 200)
    }

    func testTypesAddedForAndroidParityShareAndroidsDefaultCap() {
        let added: [HealthDataType] = [
            .vo2Max, .basalBodyTemperature, .intermenstrualBleeding, .ovulationTest, .cervicalMucus, .sexualActivity
        ]
        for type in added {
            XCTAssertEqual(SyncLimits.maxRecordsPerSync(for: type), 200, "\(type)")
        }
    }

    // MARK: - Slices

    private func minute(_ value: Int) -> Date {
        Date(timeIntervalSince1970: TimeInterval(value * 60))
    }

    func testSliceUnderTheCapReachesTheEnd() {
        let slice = SyncLimits.sliceEnd(
            probedStartDates: [minute(1), minute(2)], limit: 3, from: minute(0), to: minute(60)
        )
        XCTAssertEqual(slice.end, minute(60))
        XCTAssertTrue(slice.exact)
    }

    func testSliceAtTheCapEndsAtTheLastProbedSample() {
        // Three found with a limit of three: the third opens the next slice, so this one
        // holds two, and a capped read of it cannot drop anything.
        let slice = SyncLimits.sliceEnd(
            probedStartDates: [minute(9), minute(3), minute(5)], limit: 3, from: minute(0), to: minute(60)
        )
        XCTAssertEqual(slice.end, minute(9))
        XCTAssertTrue(slice.exact)
    }

    func testSliceMergesTheSampleTypesOfACombinedType() {
        // Total calories reads active and basal energy and caps the combined list, so the
        // boundary is the limit-th oldest across both probes.
        let active = [minute(1), minute(4), minute(7)]
        let basal = [minute(2), minute(3), minute(8)]
        let slice = SyncLimits.sliceEnd(probedStartDates: active + basal, limit: 3, from: minute(0), to: minute(60))
        XCTAssertEqual(slice.end, minute(3))
    }

    func testSlicesWalkEverySampleExactlyOnce() {
        let samples = (0..<250).map { minute($0 / 2) }  // two samples per minute, ties included
        var start = minute(0)
        let end = minute(200)
        var read: [Date] = []
        while start < end {
            let probed = Array(samples.filter { $0 >= start && $0 < end }.prefix(40))
            let slice = SyncLimits.sliceEnd(probedStartDates: probed, limit: 40, from: start, to: end)
            let inSlice = samples.filter { $0 >= start && $0 < slice.end }
            XCTAssertLessThan(inSlice.count, 36)
            read += inSlice
            start = slice.end
        }
        XCTAssertEqual(read, samples)
    }

    func testSliceLeavesATenthOfTheCapForConcurrentWrites() {
        let probed = (1...100).map(minute)
        let slice = SyncLimits.sliceEnd(probedStartDates: probed, limit: 100, from: minute(0), to: minute(500))
        // Ends at the 90th sample, so the slice holds 89 and eleven more may arrive meanwhile.
        XCTAssertEqual(slice.end, minute(90))
    }

    func testSliceThatCannotBeSplitSaysSo() {
        let slice = SyncLimits.sliceEnd(
            probedStartDates: Array(repeating: minute(5), count: 3), limit: 3, from: minute(5), to: minute(60)
        )
        XCTAssertFalse(slice.exact)
        XCTAssertGreaterThan(slice.end, minute(5))
        XCTAssertLessThan(slice.end, minute(6))
    }

    // MARK: - Catch-up over successive syncs

    /// A sample in the store, with an identity of its own, since several can share a start date.
    private struct Sample: Hashable {
        let id: Int
        let start: Date
    }

    /// A HealthKit store as the incremental sync sees it: samples in the order they were
    /// saved (the anchor is how many it has seen) and read by start date, half-open.
    private struct Store {
        var samples: [Sample] = []

        mutating func save(_ starts: [Date]) {
            for start in starts { samples.append(Sample(id: samples.count, start: start)) }
        }

        func read(from start: Date, to end: Date, limit: Int) -> [Sample] {
            Array(samples.filter { $0.start >= start && $0.start < end }
                .sorted { ($0.start, $0.id) < ($1.start, $1.id) }
                .prefix(limit))
        }
    }

    /// A small deterministic generator, so a failing case can be replayed.
    private struct Lcg {
        var state: UInt64
        mutating func next(_ bound: Int) -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((state >> 33) % UInt64(bound))
        }
    }

    /// Where a model sync is ended by iOS: before the payload is queued, after it is queued
    /// but before the anchors are saved, or not at all.
    private enum Ending {
        case beforeQueue, beforeCommit, none
    }

    /// The steps of HealthKitManager.readIncrementalDataForType for one sample type, with
    /// HealthSyncManager's write-ahead around them: a page of added samples from the anchor,
    /// the time read for the first week and its catch-up cursor, the added samples outside it
    /// by uuid, then the payload queued (and so delivered sooner or later) before the anchor
    /// and cursor are saved. Samples saved between the anchored query and the time read
    /// (`duringRead`) land behind the new anchor.
    private struct Syncer {
        let limit: Int
        var anchor: Int?
        var cursor: Date?
        var delivered: [Sample] = []
        var largestTimeRead = 0
        var largestPayload = 0

        static func uuid(_ id: Int) -> UUID {
            UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", id))!
        }

        /// What one sync sent.
        @discardableResult
        mutating func sync(_ store: inout Store, now: Date, duringRead: [Date] = [], ending: Ending = .none) -> [Sample] {
            let pageLimit = IncrementalRead.pageLimit(for: .heartRate, sampleTypeCount: 1, catchingUp: anchor == nil || cursor != nil)
            var added: [Sample] = []
            let newAnchor: Int
            var firstRead: Date?
            if let anchor {
                added = Array(store.samples[anchor..<min(anchor + pageLimit, store.samples.count)])
                newAnchor = anchor + added.count
            } else {
                newAnchor = store.samples.count
                firstRead = now.addingTimeInterval(-7 * 86_400)
            }
            let plan = IncrementalRead.plan(
                cursor: cursor, firstRead: firstRead,
                added: added.map { AddedSample(uuid: Syncer.uuid($0.id), start: $0.start, end: $0.start) }, now: now
            )
            var sent: [Sample] = []
            var newCursor: Date?
            if let start = plan.timeReadStart, start < now {
                let probe = store.read(from: start, to: now, limit: limit).map(\.start)
                let slice = SyncLimits.sliceEnd(probedStartDates: probe, limit: limit, from: start, to: now)
                store.save(duringRead)
                let read = store.read(from: start, to: slice.end, limit: limit)
                largestTimeRead = max(largestTimeRead, read.count)
                sent += read
                newCursor = SyncLimits.catchUpCursor(afterSliceEndingAt: slice.end, now: now)
            } else {
                store.save(duringRead)
            }
            let wanted = Set(plan.byUuid.map(\.uuid))
            sent += added.filter { wanted.contains(Syncer.uuid($0.id)) }
            largestPayload = max(largestPayload, sent.count)

            if ending == .beforeQueue { return [] }
            delivered += sent
            if ending == .beforeCommit { return sent }
            anchor = newAnchor
            cursor = newCursor
            return sent
        }
    }

    func testABacklogPastTheCapGoesOutWholeOverSuccessiveSyncs() {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        var rng = Lcg(state: 42)
        var store = Store()
        // Five days of heart rate, 2600 samples: more than twice the cap of 1000. Whole
        // minutes, so many samples share a start date, as a Watch's often do.
        store.save((0..<2600).map { _ in base.addingTimeInterval(TimeInterval(rng.next(5 * 1440) * 60)) })
        var syncer = Syncer(limit: 1000)
        var now = base.addingTimeInterval(5 * 86_400)

        for round in 0..<40 {
            now += 600
            // New samples keep coming, some backdated by up to a day or a year, some saved
            // mid-read, and an import of 1500 at once.
            var fresh = (0..<rng.next(40)).map { _ in now.addingTimeInterval(-TimeInterval(rng.next(600))) }
            if round % 4 == 1 { fresh.append(now.addingTimeInterval(-TimeInterval(rng.next(86_400)))) }
            if round % 7 == 3 { fresh.append(now.addingTimeInterval(-TimeInterval(300 * 86_400 + rng.next(86_400)))) }
            if round == 12 { fresh += (0..<1500).map { _ in now.addingTimeInterval(-TimeInterval(rng.next(30 * 86_400))) } }
            store.save(fresh)
            let duringRead = (0..<rng.next(30)).map { _ in now.addingTimeInterval(-TimeInterval(rng.next(3_600))) }
            let ending: Ending = round % 5 == 2 ? .beforeQueue : round % 5 == 4 ? .beforeCommit : .none
            syncer.sync(&store, now: now, duringRead: duringRead, ending: ending)
        }
        // Quiet at the end: let the last page and cursor run out.
        for _ in 0..<5 {
            now += 600
            syncer.sync(&store, now: now)
        }

        XCTAssertNil(syncer.cursor)
        XCTAssertEqual(syncer.anchor, store.samples.count)
        XCTAssertEqual(Set(store.samples).subtracting(syncer.delivered).count, 0, "samples that never went out")
        XCTAssertLessThan(syncer.largestTimeRead, 1000, "a time read reached the cap and may have cut records off")
        XCTAssertLessThanOrEqual(syncer.largestPayload, 1000, "one payload carried more than the cap")
    }

    func testABackdatedSampleSendsItselfAndNotEverythingSince() {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        var store = Store()
        store.save((0..<500).map { base.addingTimeInterval(TimeInterval($0 * 600)) })
        var syncer = Syncer(limit: 200)
        var now = base.addingTimeInterval(500 * 600)
        // The first sync reads the lookback week, over as many syncs as the cap takes.
        for _ in 0..<5 {
            now += 60
            syncer.sync(&store, now: now)
        }
        XCTAssertNil(syncer.cursor)

        now += 60
        store.save([now.addingTimeInterval(-365 * 86_400)])
        let sent = syncer.sync(&store, now: now)

        XCTAssertEqual(sent, [store.samples.last!])
    }
}
