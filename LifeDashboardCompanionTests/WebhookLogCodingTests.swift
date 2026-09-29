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

    func testDecodeLogsOfGarbageIsEmpty() {
        XCTAssertTrue(decode("not json").isEmpty)
        XCTAssertTrue(decode("{\"id\":\"A\"}").isEmpty)
        XCTAssertTrue(decode("[]").isEmpty)
    }
}
