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
}
