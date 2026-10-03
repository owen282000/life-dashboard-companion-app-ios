import Foundation

/// A payload waiting in the retry queue. It holds no headers: a retry sends the ones configured
/// at that moment, so a rotated API key reaches what was queued before. `headers` stays in the
/// file, empty, so 1.4.1 can still read the queue after a downgrade; the headers a file from
/// 1.4.1 carries are ignored and emptied when it is written again.
struct PendingSyncItem: Codable, Identifiable {
    let id: String
    let createdAt: Date
    let payload: Data
    /// The addresses it was queued for, for the log. A retry goes to the ones configured now.
    let urls: [String]
    var headers: [String: String]? = [:]
    let logType: String
    let dataType: String
    let recordCount: Int
    /// Failed deliveries, one per post that did not get through; an interrupted one does not
    /// count.
    var attemptCount: Int
    var lastAttemptAt: Date?
    var lastError: String?
    var lastStatusCode: Int?

    /// Past `PendingSyncStore.maxAge`: the next delivery that a receiver answers with a
    /// failure is its last.
    func expired(at now: Date) -> Bool {
        now.timeIntervalSince(createdAt) > PendingSyncStore.maxAge
    }
}

/// Why a payload left the queue without being delivered.
enum QueueDrop: Equatable {
    /// Still not delivered after a week; a receiver answered the attempt that found it so
    /// with a failure.
    case undelivered
    /// Refused for what it carries, still after a week, with the refusal's status code.
    case refused(Int?)
    /// Pushed out by a newer payload while the queue held `PendingSyncStore.maxItems`.
    case full
}

/// @unchecked Sendable: all data lives in individual files written atomically, and
/// FileManager is thread-safe. The one piece of memory, the ids being sent, has a lock.
final class PendingSyncStore: @unchecked Sendable {
    static let shared = PendingSyncStore()

    private let fileManager = FileManager.default
    private let sendingLock = NSLock()
    private var sending: Set<String> = []
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    /// How long a payload waits for a delivery before a failure a receiver answered drops it.
    /// Only its age counts, not its attempts: every sync, launch and network change drains the
    /// queue, and 20 attempts, the limit up to 1.4.1, ran out within an afternoon of a receiver
    /// being down. An attempt that reached no receiver, offline or cut off, drops nothing.
    static let maxAge: TimeInterval = 7 * 24 * 60 * 60

    /// The most payloads the queue holds, Android's MAX_HEALTH_ITEMS: a week of syncs every 15
    /// minutes with room for manual ones. Since an iPhone that is offline drops nothing by age,
    /// this is what bounds the queue; past it the oldest payload goes.
    static let maxItems = 700

    private let root: URL
    private let maxItems: Int

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
    init(directory: URL, maxItems: Int = PendingSyncStore.maxItems) {
        root = directory
        self.maxItems = maxItems
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
        logType: String,
        dataType: String,
        recordCount: Int
    ) -> PendingSyncItem? {
        let item = PendingSyncItem(
            id: UUID().uuidString,
            createdAt: Date(),
            payload: payload,
            urls: urls,
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

    /// The queued items, oldest first. A file that cannot be read now, as while the iPhone is
    /// locked before its first unlock, is left for the next drain; one that is read but does
    /// not decode is damaged and removed.
    func dequeueAll() -> [PendingSyncItem] {
        guard let files = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        ) else { return [] }

        var items: [PendingSyncItem] = []

        for fileURL in files where fileURL.pathExtension == "json" {
            guard let data = try? Data(contentsOf: fileURL) else { continue }
            guard let item = try? decoder.decode(PendingSyncItem.self, from: data) else {
                try? fileManager.removeItem(at: fileURL)
                continue
            }
            items.append(item)
        }

        return items.sorted { $0.createdAt < $1.createdAt }
    }

    /// Takes the oldest payloads out while the queue holds more than `maxItems`, never the one
    /// with id `keeping`, which was just written, and returns them oldest first, to be reported:
    /// their records are lost. Counting the files spares reading every payload while it fits.
    func enforceCap(keeping id: String) -> [PendingSyncItem] {
        let files = (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        )) ?? []
        guard files.filter({ $0.pathExtension == "json" }).count > maxItems else { return [] }
        let items = dequeueAll()
        guard items.count > maxItems else { return [] }
        let pushedOut = Array(items.filter { $0.id != id }.prefix(items.count - maxItems))
        pushedOut.forEach { remove(id: $0.id) }
        return pushedOut
    }

    /// The log row for an item dropped undelivered: the addresses it was queued for, its record
    /// count and payload, and why it never arrived.
    static func droppedLog(for item: PendingSyncItem, reason: QueueDrop) -> WebhookLog {
        let message: String
        var statusCode: Int?
        switch reason {
        case .undelivered:
            message = AppDiagnostic.droppedUndelivered.rawValue
        case .full:
            message = AppDiagnostic.droppedFull.rawValue
        case .refused(let code):
            statusCode = code
            message = code.map(AppDiagnostic.droppedRefused) ?? AppDiagnostic.droppedUndelivered.rawValue
        }
        return WebhookLog(
            url: item.urls.joined(separator: ", "),
            statusCode: statusCode,
            success: false,
            errorMessage: message,
            dataType: item.dataType,
            recordCount: item.recordCount,
            rawPayload: String(data: item.payload, encoding: .utf8),
            logType: LogType(rawValue: item.logType) ?? .healthConnect
        )
    }

    /// Marks an item that a sync is posting right now, so the pending count on the Health tab
    /// does not show it as waiting.
    func beginSending(id: String) {
        sendingLock.withLock { _ = sending.insert(id) }
    }

    func endSending(id: String) {
        sendingLock.withLock { _ = sending.remove(id) }
    }

    func remove(id: String) {
        let fileURL = directory.appendingPathComponent("\(id).json")
        try? fileManager.removeItem(at: fileURL)
    }

    /// Counts one failed delivery of the item, with its error and status code.
    func updateAttempt(id: String, error: String?, statusCode: Int? = nil) {
        let fileURL = directory.appendingPathComponent("\(id).json")
        guard let data = try? Data(contentsOf: fileURL),
              var item = try? decoder.decode(PendingSyncItem.self, from: data) else { return }

        item.attemptCount += 1
        item.lastAttemptAt = Date()
        item.lastError = error
        item.lastStatusCode = statusCode
        item.headers = [:]

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
        let inFlight = sendingLock.withLock { sending }
        return files?.filter {
            $0.pathExtension == "json" && !inFlight.contains($0.deletingPathExtension().lastPathComponent)
        }.count ?? 0
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
