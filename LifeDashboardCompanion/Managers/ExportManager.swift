import Foundation
import OSLog

/// MainActor: exports are user-initiated from the UI, and DateFormatter is not thread-safe.
@MainActor
final class ExportManager {
    static let shared = ExportManager()
    private let logger = Logger(subsystem: "com.owen282000.lifedashboard", category: "Export")

    private let dateFormatter = ExportManager.fixedFormatter("yyyy-MM-dd_HH-mm-ss")

    /// Android's CSV timestamp, in local time. Fixed, not the phone's date style: an export is
    /// read by scripts and spreadsheets, and reads the same whatever language the phone is in.
    private let csvDateFormatter = ExportManager.fixedFormatter("yyyy-MM-dd HH:mm:ss")

    nonisolated static func fixedFormatter(_ format: String) -> DateFormatter {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.calendar = Calendar(identifier: .gregorian)
        df.dateFormat = format
        return df
    }

    private init() {}

    // MARK: - CSV Export

    func exportLogsToCSV(logs: [WebhookLog]) -> URL? {
        var csv = "ID,Timestamp,Type,URL,Status Code,Success,Error Message,Data Type,Record Count\n"

        for log in logs {
            let timestamp = csvDateFormatter.string(from: log.timestamp)
            let statusCode = log.statusCode.map(String.init) ?? ""
            let errorMessage = csvEscape(log.errorMessage ?? "")
            let dataType = log.dataType ?? ""

            csv += "\(log.id),\(csvEscape(timestamp)),\(log.logType.rawValue),\(csvEscape(log.url)),\(statusCode),\(log.success),\(errorMessage),\(dataType),\(log.recordCount ?? 0)\n"
        }

        return writeToTempFile(content: csv, extension: "csv", prefix: "webhook_logs")
    }

    // MARK: - JSON Export

    func exportLogsToJSON(logs: [WebhookLog]) -> URL? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        guard let data = try? encoder.encode(logs),
              let jsonString = String(data: data, encoding: .utf8) else {
            return nil
        }

        return writeToTempFile(content: jsonString, extension: "json", prefix: "webhook_logs")
    }

    // MARK: - Health data export

    enum HealthExportFormat: String {
        case csv, json
    }

    enum HealthExportError: LocalizedError {
        case notSerializable

        var errorDescription: String? { AppDiagnostic.serializeFailed.localized }
    }

    /// The Health tab's Export: the preview payload (what View shows) as a file in the temporary
    /// directory, which is not backed up, for the share sheet. Only the newest export is kept
    /// there, since each one holds health data. Off the main actor: a week of heart rate is a
    /// few megabytes of text.
    nonisolated static func writeHealthExport(_ payload: [String: Any], format: HealthExportFormat, now: Date = Date()) throws -> URL {
        let data: Data
        switch format {
        case .json:
            guard let json = PayloadJSON.data(payload, options: [.prettyPrinted, .sortedKeys]) else { throw HealthExportError.notSerializable }
            data = json
        case .csv:
            data = Data(healthDataCSV(from: payload).utf8)
        }
        let directory = FileManager.default.temporaryDirectory
        let previous = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in previous where name.hasPrefix(healthExportPrefix) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
        let timestamp = fixedFormatter("yyyy-MM-dd_HH-mm-ss").string(from: now)
        let url = directory.appendingPathComponent("\(healthExportPrefix)\(timestamp).\(format.rawValue)")
        try data.write(to: url, options: .atomic)
        return url
    }

    nonisolated static let healthExportPrefix = "health_data_"

    /// Leading columns, when the payload has them; the rest follow in alphabetical order.
    private nonisolated static let leadingColumns = ["uuid", "date", "time", "start_time", "end_time", "session_end_time", "source"]

    /// The payload as one table: a row per record, `data_type` first, and a column for every
    /// field any record has, empty where a record lacks it. Numbers and booleans are written as
    /// the JSON has them, and a nested value (sleep stages, nutrients) as compact JSON in its
    /// cell. `daily_totals` rows carry `daily_totals` as their type. The payload's own fields
    /// (timestamp, app_version, source) are not records and stay in the JSON export.
    nonisolated static func healthDataCSV(from payload: [String: Any]) -> String {
        let payload = PayloadJSON.rounded(payload) as? [String: Any] ?? payload
        var rows: [(type: String, record: [String: Any])] = []
        for type in payload.keys.sorted() {
            guard let records = payload[type] as? [[String: Any]] else { continue }
            rows += records.map { (type, $0) }
        }
        let fields = Set(rows.flatMap(\.record.keys))
        let leading = leadingColumns.filter(fields.contains)
        let columns = leading + fields.subtracting(leading).sorted()

        var csv = (["data_type"] + columns).map(csvField).joined(separator: ",") + "\n"
        for row in rows {
            let cells = [row.type] + columns.map { cellText(row.record[$0]) }
            csv += cells.map(csvField).joined(separator: ",") + "\n"
        }
        return csv
    }

    private nonisolated static func cellText(_ value: Any?) -> String {
        switch value {
        case nil, is NSNull:
            return ""
        case let text as String:
            return text
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue ? "true" : "false" }
            // JSONSerialization raises on NaN and infinity; the payload never carries them.
            guard number.doubleValue.isFinite else { return "" }
            return json(number, options: .fragmentsAllowed)
        case let value?:
            guard JSONSerialization.isValidJSONObject(value) else { return "" }
            return json(value, options: [.sortedKeys, .withoutEscapingSlashes])
        }
    }

    private nonisolated static func json(_ value: Any, options: JSONSerialization.WritingOptions) -> String {
        let data = try? JSONSerialization.data(withJSONObject: value, options: options)
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    private nonisolated static let csvSpecials = CharacterSet(charactersIn: ",\"\n\r")

    private nonisolated static func csvField(_ value: String) -> String {
        if value.rangeOfCharacter(from: csvSpecials) != nil {
            return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
        }
        return value
    }

    nonisolated static func formatPayloadForPreview(_ payload: [String: Any]) -> String {
        guard let data = PayloadJSON.data(payload, options: [.prettyPrinted, .sortedKeys]),
              let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string
    }

    // MARK: - Helpers

    private func csvEscape(_ value: String) -> String {
        if value.contains(",") || value.contains("\"") || value.contains("\n") {
            return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
        }
        return value
    }

    private func writeToTempFile(content: String, extension ext: String, prefix: String) -> URL? {
        let timestamp = dateFormatter.string(from: Date())
        let fileName = "\(prefix)_\(timestamp).\(ext)"
        let tempDir = FileManager.default.temporaryDirectory
        let fileURL = tempDir.appendingPathComponent(fileName)

        do {
            try content.write(to: fileURL, atomically: true, encoding: .utf8)
            return fileURL
        } catch {
            logger.error("Failed to write export file: \(error)")
            return nil
        }
    }
}

/// The part of a payload the Logs and the Health Data Preview put on screen (P2-11), the same as
/// the Android app.
///
/// A payload can be 100,000 characters in the log and more in the preview. SwiftUI lays a Text
/// out in one go, compact JSON without spaces being the slowest case, and VoiceOver would get all
/// of it. So the screen shows the first 12,000 characters; Share has the whole payload.
///
/// `cutForDisplay` says the screen shows less than there is; `cutInStorage` says the log kept only
/// the first `LogStore.maxRawPayloadCharacters`, so sharing gives that part too. `totalCount`
/// counts what there is to show, without the log's marker.
struct PayloadPreview: Equatable, Sendable {
    /// Characters shown at most, the same on Android.
    static let maxCharacters = 12_000

    /// How far before the limit a line end may be, to end the preview on a whole line.
    private static let lineSlack = 500

    let text: String
    let totalCount: Int
    let cutForDisplay: Bool
    let cutInStorage: Bool

    /// The first `limit` characters of `payload`, ending on a whole line when one is close.
    /// Counts grapheme clusters, so an emoji is never split.
    static func of(_ payload: String, limit: Int = maxCharacters) -> PayloadPreview {
        let cutInStorage = payload.hasSuffix(LogStore.truncationMarker)
        let body = cutInStorage ? String(payload.dropLast(LogStore.truncationMarker.count)) : payload
        guard let limitIndex = body.index(body.startIndex, offsetBy: limit, limitedBy: body.endIndex),
              limitIndex < body.endIndex else {
            return PayloadPreview(text: body, totalCount: body.count, cutForDisplay: false, cutInStorage: cutInStorage)
        }
        var end = limitIndex
        let slackStart = body.index(limitIndex, offsetBy: -lineSlack, limitedBy: body.startIndex) ?? body.startIndex
        if let lineEnd = body[slackStart..<limitIndex].lastIndex(of: "\n") {
            end = lineEnd
        }
        return PayloadPreview(text: String(body[..<end]), totalCount: body.count, cutForDisplay: true, cutInStorage: cutInStorage)
    }
}
