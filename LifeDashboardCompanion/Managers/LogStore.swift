import Foundation
import OSLog

/// File-based storage for webhook logs. Raw payloads contain health data, so logs live in
/// Application Support with file protection instead of the unencrypted UserDefaults plist.
///
/// One file per row, in a directory: a new row writes its own file and the oldest past
/// `maxLogs` is deleted. Up to 1.4.1 the log was one JSON array, up to 100 rows of up to
/// 100,000 characters of payload each, read, decoded, encoded and written whole for every
/// row: some 10 MB per delivery, several times per sync. That file is split into rows once.
/// @unchecked Sendable: all file access is serialized on the internal queue.
final class LogStore: @unchecked Sendable {
    static let shared = LogStore()

    static let maxLogs = 100
    /// Raw payloads are capped so the log file stays small; the payload is for debugging only.
    static let maxRawPayloadCharacters = 100_000
    /// Ends a payload cut at `maxRawPayloadCharacters`; the preview turns it into a note (P2-11).
    static let truncationMarker = "... [truncated]"

    private let logger = Logger(subsystem: "com.owen282000.lifedashboard", category: "LogStore")
    private let queue = DispatchQueue(label: "com.owen282000.lifedashboard.logstore")
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let directory: URL
    private let legacyFile: URL?

    private convenience init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        self.init(
            directory: support.appendingPathComponent("webhook_logs", isDirectory: true),
            legacyFile: support.appendingPathComponent("webhook_logs.json")
        )
        migrateFromUserDefaultsIfNeeded()
    }

    /// The log keeps raw payloads, so it stays out of backups. `legacyFile` is the one-file log
    /// of 1.4.1 and earlier, split into rows here.
    init(directory: URL, legacyFile: URL? = nil) {
        self.directory = directory
        self.legacyFile = legacyFile
        if FileManager.default.fileExists(atPath: directory.path) {
            BackupExclusion.exclude(directory)
        }
        queue.sync { migrateLegacyFile() }
    }

    // MARK: - Public API

    func load(filterType: LogType? = nil) -> [WebhookLog] {
        queue.sync {
            let logs = readAll().map(\.log)
            guard let filterType = filterType else { return logs }
            return logs.filter { $0.logType == filterType }
        }
    }

    func add(_ log: WebhookLog) {
        queue.sync {
            write(truncated(log))
            trim()
            updateLifetimeStats(log)
        }
    }

    /// Lifetime counters shown in the hidden Nerd Stats card on the About screen.
    /// Counted per delivery (one log entry per webhook URL).
    private func updateLifetimeStats(_ log: WebhookLog) {
        guard log.countsTowardLifetime else { return }
        let defaults = UserDefaults.standard
        defaults.set(defaults.integer(forKey: "stats_total_deliveries") + 1, forKey: "stats_total_deliveries")
        if let count = log.recordCount {
            defaults.set(defaults.integer(forKey: "stats_lifetime_records") + count, forKey: "stats_lifetime_records")
        }
        if defaults.object(forKey: "stats_first_sync") == nil {
            defaults.set(log.timestamp, forKey: "stats_first_sync")
        }
        let payloadBytes = log.rawPayload?.utf8.count ?? 0
        if payloadBytes > defaults.integer(forKey: "stats_largest_payload") {
            defaults.set(payloadBytes, forKey: "stats_largest_payload")
        }
    }

    func clear(filterType: LogType? = nil) {
        queue.sync {
            if let filterType = filterType {
                for row in readAll() where row.log.logType == filterType {
                    try? FileManager.default.removeItem(at: row.file)
                }
            } else {
                try? FileManager.default.removeItem(at: directory)
            }
        }
    }

    func delete(id: String) {
        queue.sync {
            for file in rowFiles() where file.lastPathComponent.hasSuffix("-\(id).json") {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    // MARK: - Private

    /// Newest first. A file this build cannot read costs that row, not the log.
    private func readAll() -> [(log: WebhookLog, file: URL)] {
        rowFiles()
            .compactMap { file in
                guard let data = try? Data(contentsOf: file), let log = try? decoder.decode(WebhookLog.self, from: data) else {
                    return nil
                }
                return (log, file)
            }
            .sorted { ($0.log.timestamp, $0.file.lastPathComponent) > ($1.log.timestamp, $1.file.lastPathComponent) }
    }

    private func rowFiles() -> [URL] {
        let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
        )
        return (files ?? []).filter { $0.pathExtension == "json" }
    }

    /// A row's file name starts with its time in microseconds, fixed width, so the names sort
    /// oldest first without opening a file.
    static func fileName(for log: WebhookLog) -> String {
        let micros = UInt64(max(0, log.timestamp.timeIntervalSince1970) * 1_000_000)
        return String(format: "%020llu", micros) + "-\(log.id).json"
    }

    private func write(_ log: WebhookLog) {
        guard let data = try? encoder.encode(log) else { return }
        do {
            if !FileManager.default.fileExists(atPath: directory.path) {
                try LogStore.createDirectory(at: directory)
            }
            // completeUntilFirstUserAuthentication: encrypted at rest, still writable
            // during background syncs after the first unlock.
            try data.write(
                to: directory.appendingPathComponent(LogStore.fileName(for: log)),
                options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
            )
            // Again with every row: the directory's flag is what keeps the payloads out.
            BackupExclusion.exclude(directory)
        } catch {
            logger.error("Failed to write webhook log: \(error.localizedDescription)")
        }
    }

    /// Makes the log directory and marks it out of backups before the first row goes in, so no
    /// payload is ever in a directory a backup would take.
    static func createDirectory(at directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        BackupExclusion.exclude(directory)
    }

    /// Deletes the oldest rows past `maxLogs`, by file name.
    private func trim() {
        let files = rowFiles().sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard files.count > LogStore.maxLogs else { return }
        for file in files.prefix(files.count - LogStore.maxLogs) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// Decodes row by row, so a row this build cannot read costs that row and not the log:
    /// decoding the array in one go returned nothing on a single bad row.
    static func decodeLogs(from data: Data, decoder: JSONDecoder) -> [WebhookLog] {
        guard let rows = try? decoder.decode([LossyLog].self, from: data) else { return [] }
        return rows.compactMap(\.log)
    }

    private struct LossyLog: Decodable {
        let log: WebhookLog?

        init(from decoder: Decoder) throws {
            log = try? WebhookLog(from: decoder)
        }
    }

    /// Splits the one-file log of 1.4.1 and earlier into rows, and removes it.
    private func migrateLegacyFile() {
        guard let legacyFile, let data = try? Data(contentsOf: legacyFile) else { return }
        let logs = LogStore.decodeLogs(from: data, decoder: decoder)
        for log in logs.prefix(LogStore.maxLogs) {
            write(truncated(log))
        }
        try? FileManager.default.removeItem(at: legacyFile)
        logger.info("Split the webhook log into \(logs.count) row files")
    }

    private func truncated(_ log: WebhookLog) -> WebhookLog {
        guard let payload = log.rawPayload, payload.count > LogStore.maxRawPayloadCharacters else {
            return log
        }
        var copy = log
        copy.rawPayload = String(payload.prefix(LogStore.maxRawPayloadCharacters)) + LogStore.truncationMarker
        return copy
    }

    /// One-time migration of logs that older versions kept in UserDefaults.
    private func migrateFromUserDefaultsIfNeeded() {
        let key = "webhook_logs"
        guard let data = UserDefaults.standard.data(forKey: key) else { return }
        queue.sync {
            if rowFiles().isEmpty {
                let logs = LogStore.decodeLogs(from: data, decoder: decoder)
                for log in logs.prefix(LogStore.maxLogs) { write(truncated(log)) }
            }
        }
        UserDefaults.standard.removeObject(forKey: key)
        logger.info("Migrated webhook logs from UserDefaults to protected file storage")
    }
}
