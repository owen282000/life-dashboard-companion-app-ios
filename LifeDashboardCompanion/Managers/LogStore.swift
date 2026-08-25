import Foundation
import OSLog

/// File-based storage for webhook logs. Raw payloads contain health data, so logs live in
/// Application Support with file protection instead of the unencrypted UserDefaults plist.
/// @unchecked Sendable: all file access is serialized on the internal queue.
final class LogStore: @unchecked Sendable {
    static let shared = LogStore()

    static let maxLogs = 100
    /// Raw payloads are capped so the log file stays small; the payload is for debugging only.
    static let maxRawPayloadCharacters = 100_000

    private let logger = Logger(subsystem: "com.owen282000.lifedashboard", category: "LogStore")
    private let queue = DispatchQueue(label: "com.owen282000.lifedashboard.logstore")
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let fileURL: URL

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        fileURL = support.appendingPathComponent("webhook_logs.json")
        migrateFromUserDefaultsIfNeeded()
    }

    // MARK: - Public API

    func load(filterType: LogType? = nil) -> [WebhookLog] {
        queue.sync {
            let logs = readAll()
            guard let filterType = filterType else { return logs }
            return logs.filter { $0.logType == filterType }
        }
    }

    func add(_ log: WebhookLog) {
        queue.sync {
            var logs = readAll()
            logs.insert(truncated(log), at: 0)
            if logs.count > LogStore.maxLogs {
                logs = Array(logs.prefix(LogStore.maxLogs))
            }
            writeAll(logs)
            updateLifetimeStats(log)
        }
    }

    /// Lifetime counters shown in the hidden Nerd Stats card on the About screen.
    /// Counted per delivery (one log entry per webhook URL).
    private func updateLifetimeStats(_ log: WebhookLog) {
        guard log.success else { return }
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
                var logs = readAll()
                logs.removeAll { $0.logType == filterType }
                writeAll(logs)
            } else {
                try? FileManager.default.removeItem(at: fileURL)
            }
        }
    }

    func delete(id: String) {
        queue.sync {
            var logs = readAll()
            logs.removeAll { $0.id == id }
            writeAll(logs)
        }
    }

    // MARK: - Private

    private func readAll() -> [WebhookLog] {
        guard let data = try? Data(contentsOf: fileURL),
              let logs = try? decoder.decode([WebhookLog].self, from: data) else {
            return []
        }
        return logs
    }

    private func writeAll(_ logs: [WebhookLog]) {
        guard let data = try? encoder.encode(logs) else { return }
        do {
            // completeUntilFirstUserAuthentication: encrypted at rest, still writable
            // during background syncs after the first unlock.
            try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            logger.error("Failed to write webhook logs: \(error.localizedDescription)")
        }
    }

    private func truncated(_ log: WebhookLog) -> WebhookLog {
        guard let payload = log.rawPayload, payload.count > LogStore.maxRawPayloadCharacters else {
            return log
        }
        var copy = log
        copy.rawPayload = String(payload.prefix(LogStore.maxRawPayloadCharacters)) + "... [truncated]"
        return copy
    }

    /// One-time migration of logs that older versions kept in UserDefaults.
    private func migrateFromUserDefaultsIfNeeded() {
        let key = "webhook_logs"
        guard let data = UserDefaults.standard.data(forKey: key) else { return }
        if readAll().isEmpty, let logs = try? decoder.decode([WebhookLog].self, from: data) {
            writeAll(Array(logs.prefix(LogStore.maxLogs)).map(truncated))
        }
        UserDefaults.standard.removeObject(forKey: key)
        logger.info("Migrated webhook logs from UserDefaults to protected file storage")
    }
}
