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
}
