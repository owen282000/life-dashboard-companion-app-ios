import XCTest
@testable import LifeDashboardCompanion

final class SyncStatsTests: XCTestCase {

    private let base = Date(timeIntervalSince1970: 1_790_000_000)
    private var counter = 0

    /// A row `minutes` after the base date, with a unique id.
    private func row(
        _ minutes: Int,
        success: Bool = true,
        url: String = "https://home.example.com/api/webhook/secret-id",
        error: String? = nil,
        dataType: String = "health_connect",
        records: Int? = 10,
        destination: LogDestination = .webhook
    ) -> WebhookLog {
        counter += 1
        return WebhookLog(
            url: url,
            statusCode: success ? 200 : nil,
            success: success,
            errorMessage: error,
            dataType: dataType,
            recordCount: records,
            logType: .healthConnect,
            destination: destination,
            id: "row\(counter)",
            timestamp: base.addingTimeInterval(TimeInterval(minutes * 60))
        )
    }

    private func mqtt(_ minutes: Int, success: Bool = true, sensors: Int = 12) -> WebhookLog {
        row(
            minutes, success: success, url: "mqtt://broker.local:1883/lifedashboard",
            error: success ? nil : "Broker did not respond within 10 seconds",
            dataType: "mqtt", records: sensors, destination: .mqtt
        )
    }

    private func readFailure(_ minutes: Int) -> WebhookLog {
        row(
            minutes, success: false, url: "Apple Health", error: "Protected health data is inaccessible",
            dataType: WebhookLog.readFailureDataType, records: nil
        )
    }

    func testEmptyLogHasNoRateAndNoDates() {
        let stats = SyncStats(logs: [])
        XCTAssertTrue(stats.isEmpty)
        XCTAssertNil(stats.successPercent)
        XCTAssertEqual(stats.deliveries, 0)
        XCTAssertEqual(stats.records, 0)
        XCTAssertNil(stats.since)
        XCTAssertNil(stats.lastSuccess)
        XCTAssertTrue(stats.recentFailures.isEmpty)
    }

    func testRateIsRoundedDownSoAnyFailureStaysBelow100() {
        let twoOfThree = SyncStats(logs: [row(0), row(1), row(2, success: false, error: "HTTP 502")])
        XCTAssertEqual(twoOfThree.successPercent, 66)

        var logs = (0..<199).map { row($0) }
        logs.append(row(200, success: false, error: "HTTP 502"))
        XCTAssertEqual(SyncStats(logs: logs).successPercent, 99)

        XCTAssertEqual(SyncStats(logs: [row(0)]).successPercent, 100)
    }

    func testFailedRowsNeverAddRecords() {
        let stats = SyncStats(logs: [row(0, records: 10), row(1, success: false, error: "HTTP 500", records: 25)])
        XCTAssertEqual(stats.records, 10)
        XCTAssertEqual(stats.deliveries, 2)
    }

    func testRecordsCountPerDeliveredWebhookRow() {
        let stats = SyncStats(logs: [
            row(0, url: "https://a.example.com/hook", records: 10),
            row(0, url: "https://b.example.com/hook", records: 10)
        ])
        XCTAssertEqual(stats.records, 20)
    }

    func testMqttRowCountsAsDeliveryButNotRecords() {
        let stats = SyncStats(logs: [row(0, records: 10), mqtt(0, sensors: 12)])
        XCTAssertEqual(stats.deliveries, 2)
        XCTAssertEqual(stats.succeeded, 2)
        XCTAssertEqual(stats.records, 10)
    }

    func testSplitCountsPerDestination() {
        let stats = SyncStats(logs: [
            row(0), row(1, success: false, error: "HTTP 502"), mqtt(0), mqtt(1, success: false)
        ])
        XCTAssertEqual(stats.webhookDeliveries, 2)
        XCTAssertEqual(stats.webhookSucceeded, 1)
        XCTAssertEqual(stats.mqttDeliveries, 2)
        XCTAssertEqual(stats.mqttSucceeded, 1)
        XCTAssertEqual(stats.successPercent, 50)
    }

    func testReadFailureOutsideRateButInRecentFailures() {
        let stats = SyncStats(logs: [row(0), readFailure(5)])
        XCTAssertEqual(stats.deliveries, 1)
        XCTAssertEqual(stats.successPercent, 100)
        XCTAssertEqual(stats.recentFailures.map(\.source), ["Apple Health"])
        XCTAssertFalse(stats.isEmpty)
    }

    func testOnlyReadFailuresIsNotEmptyButHasNoRate() {
        let stats = SyncStats(logs: [readFailure(0)])
        XCTAssertFalse(stats.isEmpty)
        XCTAssertNil(stats.successPercent)
        XCTAssertEqual(stats.since, base)
    }

    func testUnknownDestinationCountsNowhere() throws {
        let json = #"""
        [{"id":"X","timestamp":780000000,"url":"fax://x","success":false,"errorMessage":"No tone",\#
        "recordCount":3,"logType":"HEALTH_CONNECT","destination":"FAX"}]
        """#
        let logs = LogStore.decodeLogs(from: Data(json.utf8), decoder: JSONDecoder())
        XCTAssertEqual(logs.count, 1)
        let stats = SyncStats(logs: logs)
        XCTAssertTrue(stats.isEmpty)
        XCTAssertNil(stats.since)
    }

    func testLastSuccessIsNewestSuccessEvenWhenUnsorted() {
        let stats = SyncStats(logs: [row(5), row(30, success: false, error: "HTTP 502"), row(20), row(1)])
        XCTAssertEqual(stats.lastSuccess, base.addingTimeInterval(20 * 60))
    }

    func testLastSuccessIsNilWhenEverythingFailed() {
        let stats = SyncStats(logs: [row(0, success: false, error: "HTTP 404")])
        XCTAssertNil(stats.lastSuccess)
        XCTAssertEqual(stats.successPercent, 0)
    }

    func testSinceIsOldestCountedRow() {
        let stats = SyncStats(logs: [row(40), readFailure(3), mqtt(10)])
        XCTAssertEqual(stats.since, base.addingTimeInterval(3 * 60))
    }

    func testRecentFailuresAreGroupedNewestFirstAndCappedAtThree() {
        let outage = (0..<5).map { row(100 + $0, success: false, url: "https://backup.example.org/hook", error: "HTTP 502") }
        let logs = outage + [
            row(50, success: false, url: "https://backup.example.org/hook", error: "HTTP 404"),
            mqtt(60, success: false),
            readFailure(70),
            row(10, success: false, url: "https://old.example.net/hook", error: "Timed out"),
            row(200)
        ]
        let failures = SyncStats(logs: logs).recentFailures

        XCTAssertEqual(failures.count, SyncStats.maxRecentFailures)
        XCTAssertEqual(failures.map(\.source), ["backup.example.org", "Apple Health", "MQTT"])
        XCTAssertEqual(failures[0].count, 5)
        XCTAssertEqual(failures[0].message, "HTTP 502")
        XCTAssertEqual(failures[0].latest, base.addingTimeInterval(104 * 60))
        XCTAssertEqual(failures[0].logId, outage[4].id)
        XCTAssertEqual(failures[1].count, 1)
    }

    func testFailureSourceIsHostNotFullUrl() {
        let failures = SyncStats(logs: [row(0, success: false, error: "HTTP 401")]).recentFailures
        XCTAssertEqual(failures.first?.source, "home.example.com")
        XCTAssertFalse(failures.contains { $0.source.contains("secret-id") })
    }

    func testFailureWithoutMessageKeepsNil() {
        let failures = SyncStats(logs: [row(0, success: false, error: nil)]).recentFailures
        XCTAssertEqual(failures.count, 1)
        XCTAssertNil(failures.first?.message)
    }
}
