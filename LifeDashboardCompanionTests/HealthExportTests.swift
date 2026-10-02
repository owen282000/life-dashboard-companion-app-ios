import XCTest
@testable import LifeDashboardCompanion

/// The Health tab's Export: the preview payload as CSV or JSON, in the temporary directory.
final class HealthExportTests: XCTestCase {

    private let payload: [String: Any] = [
        "timestamp": "2026-09-30T08:00:00Z",
        "app_version": "1.4.1",
        "source": "healthkit_ios",
        "steps": [
            ["uuid": "A", "count": 1200, "start_time": "2026-09-30T07:00:00Z", "end_time": "2026-09-30T07:10:00Z", "source": "iPhone"],
            ["uuid": "B", "count": 80, "start_time": "2026-09-30T07:10:00Z", "end_time": "2026-09-30T07:20:00Z", "source": "Owen's Watch, \"Series 9\""]
        ],
        "heart_rate": [
            ["uuid": "C", "bpm": 62, "time": "2026-09-30T07:05:00Z", "source": "Watch"]
        ],
        "nutrition": [
            ["uuid": "D", "time": "2026-09-30T07:30:00Z", "energy_kcal": 350.5, "meal_type": NSNull(),
             "nutrients": ["protein_grams": 12.5, "fat_grams": 3]]
        ],
        "daily_totals": [
            ["date": "2026-09-30", "steps": 1280, "distance_meters": 950.25]
        ]
    ]

    private func table(_ csv: String) -> [[String: String]] {
        let lines = csv.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        let header = parse(lines[0])
        return lines.dropFirst().map { Dictionary(uniqueKeysWithValues: zip(header, parse($0))) }
    }

    /// Enough of RFC 4180 for these rows: quoted fields with doubled quotes, no line breaks.
    private func parse(_ line: String) -> [String] {
        var fields: [String] = [], field = "", quoted = false
        var chars = Array(line)[...]
        while let char = chars.popFirst() {
            if quoted {
                if char == "\"" {
                    if chars.first == "\"" { field.append("\""); chars.removeFirst() } else { quoted = false }
                } else {
                    field.append(char)
                }
            } else if char == "\"" {
                quoted = true
            } else if char == "," {
                fields.append(field)
                field = ""
            } else {
                field.append(char)
            }
        }
        return fields + [field]
    }

    func testCsvHasARowPerRecordAndAColumnPerField() {
        let csv = ExportManager.healthDataCSV(from: payload)
        let header = parse(String(csv.prefix { $0 != "\n" }))
        XCTAssertEqual(Array(header.prefix(7)), ["data_type", "uuid", "date", "time", "start_time", "end_time", "source"])
        XCTAssertEqual(Set(header.dropFirst(7)), ["bpm", "count", "distance_meters", "energy_kcal", "meal_type", "nutrients", "steps"])

        let rows = table(csv)
        XCTAssertEqual(rows.map { $0["data_type"] }, ["daily_totals", "heart_rate", "nutrition", "steps", "steps"])
        XCTAssertFalse(rows.contains { $0["data_type"] == "timestamp" || $0["data_type"] == "app_version" },
                       "the payload's own fields are not records")
    }

    func testValuesAreWrittenAsTheJsonHasThem() {
        let rows = table(ExportManager.healthDataCSV(from: payload))
        let steps = rows.filter { $0["data_type"] == "steps" }
        XCTAssertEqual(steps[0]["count"], "1200")
        XCTAssertEqual(steps[0]["bpm"], "", "a field the record does not have is empty")
        XCTAssertEqual(steps[1]["source"], "Owen's Watch, \"Series 9\"", "commas and quotes survive the quoting")

        let nutrition = rows.first { $0["data_type"] == "nutrition" }
        XCTAssertEqual(nutrition?["energy_kcal"], "350.5")
        XCTAssertEqual(nutrition?["meal_type"], "", "null is an empty cell")
        XCTAssertEqual(nutrition?["nutrients"], #"{"fat_grams":3,"protein_grams":12.5}"#)

        let totals = rows.first { $0["data_type"] == "daily_totals" }
        XCTAssertEqual(totals?["date"], "2026-09-30")
        XCTAssertEqual(totals?["distance_meters"], "950.25")
    }

    func testAPayloadWithoutRecordsGivesOnlyTheHeader() {
        XCTAssertEqual(ExportManager.healthDataCSV(from: ["timestamp": "2026-09-30T08:00:00Z"]), "data_type\n")
    }

    func testTheFileGoesToTheTemporaryDirectoryAndReplacesTheLastExport() throws {
        let first = try ExportManager.writeHealthExport(payload, format: .json, now: Date(timeIntervalSince1970: 1_790_000_000))
        addTeardownBlock { try? FileManager.default.removeItem(at: first) }
        XCTAssertEqual(first.deletingLastPathComponent().standardizedFileURL, FileManager.default.temporaryDirectory.standardizedFileURL)
        XCTAssertTrue(first.lastPathComponent.hasPrefix("health_data_"))
        XCTAssertEqual(first.pathExtension, "json")
        let decoded = try JSONSerialization.jsonObject(with: Data(contentsOf: first)) as? [String: Any]
        XCTAssertEqual((decoded?["steps"] as? [[String: Any]])?.count, 2)
        XCTAssertEqual(decoded?["app_version"] as? String, "1.4.1", "the JSON is the whole payload, as View shows it")

        let second = try ExportManager.writeHealthExport(payload, format: .csv, now: Date(timeIntervalSince1970: 1_790_000_060))
        addTeardownBlock { try? FileManager.default.removeItem(at: second) }
        XCTAssertEqual(second.pathExtension, "csv")
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path), "an export holds health data: only the newest stays")
        XCTAssertEqual(try String(contentsOf: second, encoding: .utf8), ExportManager.healthDataCSV(from: payload))
    }

    // MARK: - What the screen shows of a payload (P2-11)

    func testAShortPayloadIsShownWhole() {
        let preview = PayloadPreview.of("{\"steps\":[]}")
        XCTAssertEqual(preview.text, "{\"steps\":[]}")
        XCTAssertFalse(preview.cutForDisplay)
        XCTAssertFalse(preview.cutInStorage)
    }

    func testAPayloadOfExactlyTheLimitIsShownWhole() {
        let preview = PayloadPreview.of(String(repeating: "a", count: PayloadPreview.maxCharacters))
        XCTAssertEqual(preview.text.count, PayloadPreview.maxCharacters)
        XCTAssertFalse(preview.cutForDisplay)
    }

    func testALongPayloadStopsAtTwelveThousandCharactersAndKnowsItsLength() {
        let preview = PayloadPreview.of(String(repeating: "a", count: 300_000))
        XCTAssertEqual(preview.text.count, 12_000, "the same limit as Android")
        XCTAssertEqual(preview.totalCount, 300_000)
        XCTAssertTrue(preview.cutForDisplay)
        XCTAssertFalse(preview.cutInStorage)
    }

    func testACutEndsOnALineWhenOneIsClose() {
        let line = "  \"count\" : 1234,\n"
        let payload = String(repeating: line, count: PayloadPreview.maxCharacters / line.count + 100)
        let preview = PayloadPreview.of(payload)
        XCTAssertLessThanOrEqual(preview.text.count, PayloadPreview.maxCharacters)
        XCTAssertTrue(payload.hasPrefix(preview.text + "\n"), "ends on a whole line")
    }

    func testTheCutNeverSplitsAnEmoji() {
        let payload = String(repeating: "a", count: PayloadPreview.maxCharacters - 1) + "👍🏽" + String(repeating: "a", count: 100)
        let preview = PayloadPreview.of(payload)
        XCTAssertEqual(preview.text.last, "👍🏽")
        XCTAssertEqual(preview.text.count, PayloadPreview.maxCharacters)
    }

    func testTheLogsMarkerBecomesAFlagAndLeavesTheText() {
        let stored = String(repeating: "a", count: LogStore.maxRawPayloadCharacters) + LogStore.truncationMarker
        let preview = PayloadPreview.of(stored)
        XCTAssertTrue(preview.cutInStorage)
        XCTAssertFalse(preview.text.contains("[truncated]"))
        XCTAssertEqual(preview.totalCount, LogStore.maxRawPayloadCharacters)
    }
}
