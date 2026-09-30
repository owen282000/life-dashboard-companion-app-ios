import XCTest
@testable import LifeDashboardCompanion

final class WebhookLogCodingTests: XCTestCase {

    /// A row as 1.3.0 wrote it: synthesized Codable, the date as seconds since 2001.
    private let row130 = """
    {"id":"A","timestamp":780000000,"url":"https://example.com/hook","statusCode":200,\
    "success":true,"dataType":"health_connect","recordCount":42,"logType":"HEALTH_CONNECT"}
    """

    private func decode(_ json: String) -> [WebhookLog] {
        LogStore.decodeLogs(from: Data(json.utf8), decoder: JSONDecoder())
    }

    func testRowFrom130Decodes() {
        let logs = decode("[\(row130)]")
        XCTAssertEqual(logs.count, 1)
        XCTAssertEqual(logs.first?.id, "A")
        XCTAssertEqual(logs.first?.recordCount, 42)
    }

    func testDecodeLogsKeepsGoodRowsWhenOneRowIsCorrupt() {
        // A log type this build does not know, and a row missing a required key.
        let unknownType = row130.replacingOccurrences(of: "HEALTH_CONNECT", with: "SCREEN_TIME")
            .replacingOccurrences(of: "\"A\"", with: "\"B\"")
        let missingKey = #"{"id":"C","url":"x","success":false,"logType":"HEALTH_CONNECT"}"#
        let logs = decode("[\(row130),\(unknownType),\(missingKey)]")
        XCTAssertEqual(logs.map(\.id), ["A"])
    }

    func testRowFrom130WithoutDestinationIsAWebhook() throws {
        let log = try XCTUnwrap(decode("[\(row130)]").first)
        XCTAssertNil(log.destination)
        XCTAssertEqual(log.syncKind, .webhook)
        XCTAssertTrue(log.countsTowardLifetime)
    }

    func testUnknownDestinationDecodesAndCountsNowhere() throws {
        let row = row130.replacingOccurrences(of: "\"logType\"", with: "\"destination\":\"FAX\",\"logType\"")
        let log = try XCTUnwrap(decode("[\(row)]").first)
        XCTAssertEqual(log.destination, "FAX")
        XCTAssertEqual(log.syncKind, .other)
        XCTAssertFalse(log.countsTowardLifetime)
    }

    func testMqttRowRoundTrips() throws {
        let log = WebhookLog(
            url: "mqtt://broker.local:1883/lifedashboard",
            success: true,
            dataType: "mqtt",
            recordCount: 12,
            logType: .healthConnect,
            destination: .mqtt
        )
        let json = try XCTUnwrap(String(bytes: JSONEncoder().encode([log]), encoding: .utf8))
        XCTAssertTrue(json.contains("\"destination\":\"MQTT\""))
        let decoded = try XCTUnwrap(decode(json).first)
        XCTAssertEqual(decoded.syncKind, .mqtt)
        XCTAssertEqual(decoded.recordCount, 12)
    }

    func testNewWebhookRowsNameTheirDestination() {
        let log = WebhookLog(url: "https://example.com", success: true, recordCount: 1, logType: .healthConnect)
        XCTAssertEqual(log.destination, "WEBHOOK")
    }

    func testMarkedReadFailure() {
        let marked = WebhookLog(
            url: "Apple Health", success: false, errorMessage: "Protected data unavailable",
            dataType: WebhookLog.readFailureDataType, logType: .healthConnect
        )
        XCTAssertEqual(marked.syncKind, .readFailure)
        XCTAssertFalse(marked.countsTowardLifetime)
    }

    func testLegacyReadFailureIsRecognisedByMissingRecordCount() {
        // 1.3.0 wrote the read failure with the first webhook URL and no record count.
        let legacy = #"""
        {"id":"R","timestamp":780000000,"url":"https://example.com/hook","success":false,"errorMessage":"Read failed","dataType":"health_connect","logType":"HEALTH_CONNECT"}
        """#
        let legacyRows = decode("[\(legacy)]")
        XCTAssertEqual(legacyRows.count, 1)
        XCTAssertEqual(legacyRows.first?.syncKind, .readFailure)

        let failedDelivery = legacy.replacingOccurrences(of: "\"logType\"", with: "\"recordCount\":10,\"logType\"")
        XCTAssertEqual(decode("[\(failedDelivery)]").first?.syncKind, .webhook)
    }

    func testFailedRowsFromThisBuildAreNotReadFailures() {
        let failedPublish = WebhookLog(
            url: "mqtt://broker.local:1883/lifedashboard", success: false, dataType: "mqtt",
            logType: .healthConnect, destination: .mqtt
        )
        XCTAssertEqual(failedPublish.syncKind, .mqtt)

        let failedWithoutCount = WebhookLog(url: "https://example.com", success: false, logType: .healthConnect)
        XCTAssertEqual(failedWithoutCount.syncKind, .webhook)
    }

    func testOnlyDeliveredWebhookRowsCountTowardLifetime() {
        let delivered = WebhookLog(url: "https://example.com", success: true, recordCount: 5, logType: .healthConnect)
        let failed = WebhookLog(url: "https://example.com", success: false, recordCount: 5, logType: .healthConnect)
        let published = WebhookLog(
            url: "mqtt://broker.local:1883/lifedashboard", success: true, recordCount: 12,
            logType: .healthConnect, destination: .mqtt
        )
        XCTAssertTrue(delivered.countsTowardLifetime)
        XCTAssertFalse(failed.countsTowardLifetime)
        XCTAssertFalse(published.countsTowardLifetime)
    }

    func testDecodeLogsOfGarbageIsEmpty() {
        XCTAssertTrue(decode("not json").isEmpty)
        XCTAssertTrue(decode("{\"id\":\"A\"}").isEmpty)
        XCTAssertTrue(decode("[]").isEmpty)
    }
}

/// The log and the retry queue hold health data, so neither may reach an iCloud or computer
/// backup, also after an atomic write has put a new file in place.
final class BackupExclusionTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("backup-exclusion-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// Read through a fresh URL: a URL caches the resource values it has read.
    private func isExcluded(_ url: URL) throws -> Bool {
        let fresh = URL(fileURLWithPath: url.path)
        return try fresh.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true
    }

    private func failedRow() -> WebhookLog {
        // Not delivered, so the lifetime counters in UserDefaults stay as they are.
        WebhookLog(url: "https://example.com/hook", success: false, errorMessage: "HTTP 500", logType: .healthConnect)
    }

    func testTheLogFileStaysOutOfBackupsAfterEveryWrite() throws {
        let file = root.appendingPathComponent("webhook_logs.json")
        let store = LogStore(fileURL: file)
        store.add(failedRow())
        XCTAssertTrue(try isExcluded(file))

        // Each add replaces the file; the new one is marked again.
        store.add(failedRow())
        XCTAssertEqual(store.load().count, 2)
        XCTAssertTrue(try isExcluded(file))
    }

    func testALogFileFromAnEarlierVersionIsMarkedWhenTheStoreOpens() throws {
        let file = root.appendingPathComponent("webhook_logs.json")
        try Data("[]".utf8).write(to: file)
        XCTAssertFalse(try isExcluded(file))
        _ = LogStore(fileURL: file)
        XCTAssertTrue(try isExcluded(file))
    }

    func testTheQueueDirectoryStaysOutOfBackups() throws {
        let directory = root.appendingPathComponent("pending_sync", isDirectory: true)
        let store = PendingSyncStore(directory: directory)
        XCTAssertTrue(store.enqueue(
            payload: Data("{}".utf8), urls: ["https://example.com/hook"], headers: [:],
            logType: LogType.healthConnect.rawValue, dataType: "health_connect", recordCount: 1
        ))
        XCTAssertTrue(try isExcluded(directory))
        XCTAssertEqual(store.pendingCount, 1)
    }

    func testAQueueDirectoryFromAnEarlierVersionIsMarkedWhenTheStoreOpens() throws {
        let directory = root.appendingPathComponent("pending_sync", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        XCTAssertFalse(try isExcluded(directory))
        _ = PendingSyncStore(directory: directory)
        XCTAssertTrue(try isExcluded(directory))
    }
}
