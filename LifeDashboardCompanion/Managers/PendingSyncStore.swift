import Foundation

struct PendingSyncItem: Codable, Identifiable {
    let id: String
    let createdAt: Date
    let payload: Data
    let urls: [String]
    let headers: [String: String]
    let logType: String
    let dataType: String
    let recordCount: Int
    var attemptCount: Int
    var lastAttemptAt: Date?
    var lastError: String?
}

/// @unchecked Sendable: the store keeps no in-memory state; all data lives in
/// individual files written atomically, and FileManager is thread-safe.
final class PendingSyncStore: @unchecked Sendable {
    static let shared = PendingSyncStore()

    private let fileManager = FileManager.default
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let maxAge: TimeInterval = 7 * 24 * 60 * 60 // 7 days
    private let maxAttempts = 20

    private var directory: URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("pending_sync", isDirectory: true)
        if !fileManager.fileExists(atPath: dir.path) {
            try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    private init() {}

    // MARK: - Public API

    func enqueue(
        payload: Data,
        urls: [String],
        headers: [String: String],
        logType: String,
        dataType: String,
        recordCount: Int
    ) {
        let item = PendingSyncItem(
            id: UUID().uuidString,
            createdAt: Date(),
            payload: payload,
            urls: urls,
            headers: headers,
            logType: logType,
            dataType: dataType,
            recordCount: recordCount,
            attemptCount: 0,
            lastAttemptAt: nil,
            lastError: nil
        )

        let fileURL = directory.appendingPathComponent("\(item.id).json")
        if let data = try? encoder.encode(item) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    func dequeueAll() -> [PendingSyncItem] {
        guard let files = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        ) else { return [] }

        var items: [PendingSyncItem] = []
        let now = Date()

        for fileURL in files where fileURL.pathExtension == "json" {
            guard let data = try? Data(contentsOf: fileURL),
                  let item = try? decoder.decode(PendingSyncItem.self, from: data) else {
                // Corrupted file - remove it
                try? fileManager.removeItem(at: fileURL)
                continue
            }

            // Purge expired or over-attempted items
            if now.timeIntervalSince(item.createdAt) > maxAge || item.attemptCount >= maxAttempts {
                try? fileManager.removeItem(at: fileURL)
                continue
            }

            items.append(item)
        }

        return items.sorted { $0.createdAt < $1.createdAt }
    }

    func remove(id: String) {
        let fileURL = directory.appendingPathComponent("\(id).json")
        try? fileManager.removeItem(at: fileURL)
    }

    func updateAttempt(id: String, error: String?) {
        let fileURL = directory.appendingPathComponent("\(id).json")
        guard let data = try? Data(contentsOf: fileURL),
              var item = try? decoder.decode(PendingSyncItem.self, from: data) else { return }

        item.attemptCount += 1
        item.lastAttemptAt = Date()
        item.lastError = error

        if let updated = try? encoder.encode(item) {
            try? updated.write(to: fileURL, options: .atomic)
        }
    }

    var pendingCount: Int {
        let files = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        )
        return files?.filter { $0.pathExtension == "json" }.count ?? 0
    }

    func clearAll() {
        guard let files = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        ) else { return }

        for fileURL in files {
            try? fileManager.removeItem(at: fileURL)
        }
    }
}

/// Lets one piece of async work run at a time. A caller that arrives while it runs waits for
/// that run and does not start a second one. The retry queue is drained from app launch,
/// becoming active, the network coming back, both background tasks and Retry Now; the store
/// hands every drain the same files, so two drains at once posted each payload twice.
///
/// A caller that arrives mid-run also asks for one more run once this one ends, so an item
/// queued after the running drain listed the files is not left for the next trigger. Cancelling
/// the caller that started the work cancels the work, as a background task that runs out of
/// time does; a caller that only waits leaves it running.
actor SingleFlight {
    private var current: Task<Void, Never>?
    private var rerunRequested = false

    /// Runs `work`, or waits for the run already in flight. True when this call ran it.
    @discardableResult
    func run(_ work: @escaping @Sendable () async -> Void) async -> Bool {
        if let current {
            rerunRequested = true
            await current.value
            return false
        }
        repeat {
            rerunRequested = false
            let task = Task { await work() }
            current = task
            await withTaskCancellationHandler {
                await task.value
            } onCancel: {
                task.cancel()
            }
            current = nil
        } while rerunRequested && !Task.isCancelled
        return true
    }
}
