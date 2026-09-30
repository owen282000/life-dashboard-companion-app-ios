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

    nonisolated static func formatPayloadForPreview(_ payload: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]),
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
