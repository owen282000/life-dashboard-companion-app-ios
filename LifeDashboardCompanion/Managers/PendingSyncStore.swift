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

    private let root: URL

    private var directory: URL {
        if !fileManager.fileExists(atPath: root.path) {
            try? fileManager.createDirectory(at: root, withIntermediateDirectories: true)
            BackupExclusion.exclude(root)
        }
        return root
    }

    private convenience init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.init(directory: appSupport.appendingPathComponent("pending_sync", isDirectory: true))
    }

    /// The queue holds whole payloads, so it stays out of backups. A directory from 1.4.0 and
    /// earlier is in them until this marks it.
    init(directory: URL) {
        root = directory
        if fileManager.fileExists(atPath: root.path) {
            BackupExclusion.exclude(root)
        }
    }

    // MARK: - Public API

    /// The item once it is on disk, which is what lets a caller forget what it carries; nil
    /// when it could not be written.
    @discardableResult
    func enqueue(
        payload: Data,
        urls: [String],
        headers: [String: String],
        logType: String,
        dataType: String,
        recordCount: Int
    ) -> PendingSyncItem? {
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
        guard let data = try? encoder.encode(item) else { return nil }
        do {
            try data.write(to: fileURL, options: PendingSyncStore.writeOptions)
            // Again with every file: the directory's flag is all that keeps the payload out.
            BackupExclusion.exclude(directory)
            return item
        } catch {
            return nil
        }
    }

    /// Encrypted at rest and still writable in the background after the first unlock, when a
    /// HealthKit wakeup writes the payload before posting it.
    private static let writeOptions: Data.WritingOptions = [.atomic, .completeFileProtectionUntilFirstUserAuthentication]

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
            try? updated.write(to: fileURL, options: PendingSyncStore.writeOptions)
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

/// Keeps a file or directory out of iCloud and computer backups, so the health data the app keeps
/// stays on the iPhone. The flag belongs to the item: an atomic write puts a new file in place
/// and loses it, so a file that is not inside an excluded directory is marked after every write.
enum BackupExclusion {
    @discardableResult
    static func exclude(_ url: URL) -> Bool {
        var item = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        return (try? item.setResourceValues(values)) != nil
    }
}

/// Lets one run of a job go at a time. A caller that finds a run under way does not start a
/// second one: it hands its items to that run, which takes them in one more round before it
/// ends. Two jobs use it.
///
/// The retry queue drain goes through `run`. Every caller reaches it through SyncCoordinator,
/// whose one flight already keeps two drains apart; the store hands every drain the same files,
/// so a caller that came in any other way would post each payload twice, and this flight stops
/// that. A caller that arrives mid-drain waits until the run is over, including the one more
/// round its arrival asked for, so an item queued after the running drain listed the files is
/// not left for the next trigger. Cancelling the caller that started the work cancels the work,
/// as a background task that runs out of time does; a caller that only waits leaves it running.
///
/// The incremental sync goes through `enter` and `next`: a second caller hands over its data
/// types and returns at once, and the running sync reads them in one more round.
actor SingleFlight<Item: Hashable & Sendable> {
    private var running = false
    private var rerunRequested = false
    private var pending: Set<Item> = []
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// True when the caller may run now. False when a run is under way; `items` are then
    /// handed to it through `next()`.
    func enter(_ items: Set<Item> = []) -> Bool {
        if running {
            pending.formUnion(items)
            rerunRequested = true
            return false
        }
        running = true
        return true
    }

    /// What was handed over while the current round ran, for one more round, or nil when no
    /// caller arrived: the run is then over and the next `enter` starts a new one.
    func next() -> Set<Item>? {
        guard rerunRequested else {
            finish()
            return nil
        }
        rerunRequested = false
        defer { pending.removeAll() }
        return pending
    }

    /// Runs `work`, or waits for the run already in flight. True when this call ran it.
    @discardableResult
    func run(_ work: @escaping @Sendable () async -> Void) async -> Bool {
        guard enter() else {
            await withCheckedContinuation { waiters.append($0) }
            return false
        }
        repeat {
            let task = Task { await work() }
            await withTaskCancellationHandler {
                await task.value
            } onCancel: {
                task.cancel()
            }
        } while !Task.isCancelled && next() != nil
        // Cancelled: the rounds asked for are dropped, as the whole drain is.
        if running { finish() }
        return true
    }

    private func finish() {
        running = false
        rerunRequested = false
        pending.removeAll()
        let released = waiters
        waiters.removeAll()
        released.forEach { $0.resume() }
    }
}
