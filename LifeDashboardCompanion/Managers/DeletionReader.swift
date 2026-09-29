import Foundation
import HealthKit
import OSLog
import UIKit

// MARK: - Source

/// One page of a target's deletions: the uuids and the anchor after them (archived).
struct DeletedPage: Sendable {
    let uuids: [String]
    let anchor: Data?
}

enum DeletionReadError: Error, Equatable {
    /// The phone is locked and HealthKit's store is encrypted; nothing can be read now.
    case databaseInaccessible
    case failed(String)
}

/// Where deletions come from. HealthKit in the app, a script in the tests.
protocol DeletedObjectSource: Sendable {
    func deletedPage(sampleTypeIdentifier: String, anchor: Data?, limit: Int, timeout: Duration) async throws -> DeletedPage
}

/// Reads deletions with an anchored query whose predicate matches no sample. HealthKit applies a
/// predicate to samples only, not to deleted objects, so the query returns just the deletions
/// since the anchor and never loads a sample. Its anchor moves only past what it returned, so it
/// is kept apart from the records path's anchors.
struct HealthKitDeletionSource: DeletedObjectSource {
    let healthKit: HealthKitManager

    func deletedPage(sampleTypeIdentifier: String, anchor: Data?, limit: Int, timeout: Duration) async throws -> DeletedPage {
        guard let sampleType = Self.sampleType(for: sampleTypeIdentifier) else {
            throw DeletionReadError.failed("Unknown sample type \(sampleTypeIdentifier)")
        }
        var startAnchor: HKQueryAnchor?
        if let anchor {
            startAnchor = try? NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: anchor)
            // Querying from nil instead would report every deletion HealthKit still remembers.
            guard startAnchor != nil else { throw DeletionReadError.failed("Stored anchor unreadable") }
        }
        let store = healthKit.healthStore
        let begin = QueryStart(sampleType: sampleType, anchor: startAnchor, limit: limit)
        return try await BoundedCall.run(timeout: timeout) { finish in
            let query = HKAnchoredObjectQuery(
                type: begin.sampleType,
                predicate: HKQuery.predicateForObjects(with: Set<UUID>()),
                anchor: begin.anchor,
                limit: begin.limit
            ) { _, _, deletedObjects, newAnchor, error in
                if let error {
                    let inaccessible = (error as? HKError)?.code == .errorDatabaseInaccessible
                    finish(.failure(inaccessible ? DeletionReadError.databaseInaccessible : DeletionReadError.failed(error.localizedDescription)))
                    return
                }
                let data = newAnchor.flatMap {
                    try? NSKeyedArchiver.archivedData(withRootObject: $0, requiringSecureCoding: true)
                }
                finish(.success(DeletedPage(uuids: (deletedObjects ?? []).map { $0.uuid.uuidString }, anchor: data)))
            }
            store.execute(query)
            let running = RunningQuery(query: query)
            return { store.stop(running.query) }
        }
    }

    static func sampleType(for identifier: String) -> HKSampleType? {
        HealthDataType.allCases.lazy.flatMap(\.deletionSampleTypes).first { $0.identifier == identifier }
    }

    /// @unchecked Sendable: HealthKit query objects are immutable once configured and
    /// HKHealthStore accepts them from any thread.
    private struct QueryStart: @unchecked Sendable {
        let sampleType: HKSampleType
        let anchor: HKQueryAnchor?
        let limit: Int
    }

    private final class RunningQuery: @unchecked Sendable {
        let query: HKQuery
        init(query: HKQuery) { self.query = query }
    }
}

// MARK: - Store

/// Where a target stands: registering (from no anchor, reading past what HealthKit remembers
/// without reporting it) or tracking (everything after the anchor is a new deletion).
struct DeletionTargetState: Codable, Equatable, Sendable {
    enum Phase: String, Codable, Sendable {
        case registering
        case tracking
    }

    var anchor: Data?
    var phase: Phase = .registering
    var lastCompleteReadAt: Date?
    var consecutiveErrors = 0
}

/// Everything deletion tracking keeps: one file, so a page's deletions and its anchor are
/// stored in one atomic write. An anchor stored without its deletions would lose them for good.
struct DeletionState: Codable, Equatable, Sendable {
    var generation = 0
    var targets: [String: DeletionTargetState] = [:]
    var pending: [PendingDeletion] = []
    var unavailable: [String: Int] = [:]

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        generation = try container.decodeIfPresent(Int.self, forKey: .generation) ?? 0
        targets = try container.decodeIfPresent([String: DeletionTargetState].self, forKey: .targets) ?? [:]
        pending = try container.decodeIfPresent([PendingDeletion].self, forKey: .pending) ?? []
        unavailable = try container.decodeIfPresent([String: Int].self, forKey: .unavailable) ?? [:]
    }
}

enum DeletionStoreError: Error {
    /// The file exists but cannot be read yet, as before the first unlock after a restart.
    case unreadable
    case writeFailed(String)
}

/// The deletion state on disk. An actor whose methods never suspend, so each one is a single
/// read-modify-write that no other sync can interleave with.
actor DeletionStore {
    static let shared = DeletionStore(
        directory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("deletion_tracking", isDirectory: true)
    )

    /// Set once state has been written. It is in the backup while the state directory is not,
    /// so "flag set, file gone" means the state was lost (a restore onto another phone) and the
    /// types are named once, while a first start names nothing.
    static let startedKey = "deletion_tracking_started"

    private let directory: URL
    private let fileURL: URL
    private let defaults: UserDefaults
    private let logger = Logger(subsystem: "com.owen282000.lifedashboard", category: "DeletionStore")
    private var state: DeletionState?
    private var stateLost = false

    init(directory: URL, defaults: UserDefaults = .standard) {
        self.directory = directory
        self.fileURL = directory.appendingPathComponent("state.json")
        self.defaults = defaults
    }

    /// Loads the state. True once when it was lost, so the caller names every type.
    func begin() throws -> Bool {
        _ = try load()
        defer { stateLost = false }
        return stateLost
    }

    var generation: Int { (try? load().generation) ?? 0 }

    func target(_ key: String) -> DeletionTargetState? {
        try? load().targets[key]
    }

    func snapshot() -> DeletionState? {
        try? load()
    }

    /// Stores one page: the target's new anchor and phase and the deletions it passed, together.
    func commitPage(
        target key: String,
        anchor: Data?,
        phase: DeletionTargetState.Phase,
        deletions: [DeletedRecord],
        completedAt: Date?
    ) throws {
        var next = try load()
        if !deletions.isEmpty {
            next.generation += 1
            let known = Set(next.pending.map(\.record))
            for record in deletions where !known.contains(record) {
                next.pending.append(PendingDeletion(record: record, generation: next.generation))
            }
        }
        var target = next.targets[key] ?? DeletionTargetState()
        target.anchor = anchor
        target.phase = phase
        target.consecutiveErrors = 0
        if let completedAt { target.lastCompleteReadAt = completedAt }
        next.targets[key] = target
        try save(next)
    }

    /// Counts a failed read. After `maxConsecutiveErrors` the target starts over.
    func recordError(target key: String) throws {
        var next = try load()
        var target = next.targets[key] ?? DeletionTargetState()
        target.consecutiveErrors += 1
        if target.consecutiveErrors >= DeletionTracking.maxConsecutiveErrors {
            target = DeletionTargetState()
        }
        next.targets[key] = target
        try save(next)
    }

    /// Names payload keys in `deletions_unavailable` until a payload carries them.
    func markUnavailable(_ keys: Set<String>) throws {
        guard !keys.isEmpty else { return }
        var next = try load()
        next.generation += 1
        for key in keys { next.unavailable[key] = next.generation }
        try save(next)
    }

    /// What the next payload carries; drops stale deletions from storage right away.
    func plan(readIds: [String: Set<String>], readGeneration: Int) -> DeletionPlan {
        guard var current = try? load() else { return DeletionPlan() }
        let plan = DeletionTracking.plan(
            pending: current.pending,
            unavailable: current.unavailable,
            readIds: readIds,
            readGeneration: readGeneration
        )
        if !plan.stale.isEmpty {
            let stale = Set(plan.stale)
            current.pending.removeAll { stale.contains($0) }
            try? save(current)
        }
        return plan
    }

    /// Removes what a delivered or queued payload carried, and nothing added since.
    func remove(_ carried: CarriedDeletions) {
        guard !carried.isEmpty, var current = try? load() else { return }
        let gone = Set(carried.deletions)
        current.pending.removeAll { gone.contains($0) }
        for (key, generation) in carried.unavailable where current.unavailable[key] == generation {
            current.unavailable[key] = nil
        }
        try? save(current)
    }

    // MARK: File

    private func load() throws -> DeletionState {
        if let state { return state }
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: fileURL.path) else {
            stateLost = defaults.bool(forKey: Self.startedKey)
            let fresh = DeletionState()
            state = fresh
            return fresh
        }
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            throw DeletionStoreError.unreadable
        }
        do {
            let decoded = try JSONDecoder().decode(DeletionState.self, from: data)
            state = decoded
            return decoded
        } catch {
            // Keep the damaged file for a look, start over, and say so once.
            let aside = directory.appendingPathComponent("state.corrupt.json")
            try? fileManager.removeItem(at: aside)
            try? fileManager.moveItem(at: fileURL, to: aside)
            logger.error("Deletion state unreadable, starting over: \(error.localizedDescription)")
            stateLost = true
            let fresh = DeletionState()
            state = fresh
            return fresh
        }
    }

    private func save(_ next: DeletionState) throws {
        do {
            let fileManager = FileManager.default
            if !fileManager.fileExists(atPath: directory.path) {
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
                // On the directory, not the file: an atomic write replaces the file, and with it
                // any resource value set on it. An anchor restored onto another phone would point
                // into another HealthKit database.
                var values = URLResourceValues()
                values.isExcludedFromBackup = true
                var excluded = directory
                try excluded.setResourceValues(values)
            }
            let data = try JSONEncoder().encode(next)
            try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            throw DeletionStoreError.writeFailed(error.localizedDescription)
        }
        state = next
        defaults.set(true, forKey: Self.startedKey)
    }
}

// MARK: - Reader

/// Reads every target's new deletions into the store, within a time budget.
struct DeletionReader: Sendable {
    enum Outcome: Equatable, Sendable {
        /// Nothing could be read now (locked, or the store unreadable); nothing was named.
        case skipped
        /// The payload keys named in `deletions_unavailable` by this read.
        case done(unavailable: Set<String>)
    }

    let source: DeletedObjectSource
    let store: DeletionStore
    var perTarget: Duration = DeletionTracking.perTargetTimeout
    var pageLimit = DeletionTracking.pageLimit
    var maxPages = DeletionTracking.maxPagesPerTarget
    var now: @Sendable () -> Date = { Date() }

    func read(targets: [DeletionTarget], budget: Duration) async -> Outcome {
        let lost: Bool
        do {
            lost = try await store.begin()
        } catch {
            return .skipped
        }
        var unavailable = Set<String>()
        if lost { unavailable.formUnion(targets.map(\.payloadKey)) }

        let clock = ContinuousClock()
        let stepStart = clock.now
        var stopAll = false

        for target in targets {
            let state = await store.target(target.key) ?? DeletionTargetState()
            let tracking = state.phase == .tracking
            if stopAll {
                if tracking { unavailable.insert(target.payloadKey) }
                continue
            }
            if tracking && DeletionTracking.isStale(lastCompleteReadAt: state.lastCompleteReadAt, now: now()) {
                unavailable.insert(target.payloadKey)
            }

            let targetStart = clock.now
            var anchor = state.anchor
            var phase = state.phase
            var vouched = false

            for _ in 0..<maxPages {
                let fromTarget = DeletionTracking.timeoutFor(elapsed: clock.now - targetStart, perTarget: perTarget, total: perTarget)
                let fromStep = DeletionTracking.timeoutFor(elapsed: clock.now - stepStart, perTarget: perTarget, total: budget)
                let timeout = min(fromTarget, fromStep)
                if timeout == .zero || Task.isCancelled {
                    stopAll = stopAll || fromStep == .zero || Task.isCancelled
                    break
                }

                let page: DeletedPage
                do {
                    page = try await source.deletedPage(
                        sampleTypeIdentifier: target.sampleTypeIdentifier,
                        anchor: anchor,
                        limit: pageLimit,
                        timeout: timeout
                    )
                } catch DeletionReadError.databaseInaccessible {
                    return .skipped
                } catch is CancellationError {
                    stopAll = true
                    break
                } catch is BoundedCall.TimedOut {
                    // Slow is not refused: the anchor is kept and read again next sync.
                    break
                } catch {
                    try? await store.recordError(target: target.key)
                    break
                }

                let nextAnchor = page.anchor ?? anchor
                if !page.uuids.isEmpty && nextAnchor == anchor {
                    // Deletions without progress: the next page would return them again.
                    break
                }
                let reachedEnd = page.uuids.isEmpty
                if reachedEnd && phase == .registering && nextAnchor != nil { phase = .tracking }
                // Registration passes what HealthKit still remembers from before; none of it is new.
                let deletions = tracking
                    ? page.uuids.map { DeletedRecord(type: target.payloadKey, uuid: $0) }
                    : []
                do {
                    try await store.commitPage(
                        target: target.key,
                        anchor: nextAnchor,
                        phase: phase,
                        deletions: deletions,
                        completedAt: reachedEnd && phase == .tracking ? now() : nil
                    )
                } catch {
                    break
                }
                anchor = nextAnchor
                if reachedEnd {
                    vouched = true
                    break
                }
            }

            if tracking && !vouched { unavailable.insert(target.payloadKey) }
        }

        do {
            try await store.markUnavailable(unavailable)
        } catch {
            return .skipped
        }
        return .done(unavailable: unavailable)
    }
}

// MARK: - Step

/// The deletion step of a sync: runs before the records read, so a record deleted while the
/// sync runs is read as deleted and not as a record.
enum DeletionStep {
    static let reader = DeletionReader(
        source: HealthKitDeletionSource(healthKit: .shared),
        store: .shared
    )

    /// Reads the enabled types' deletions and returns the store generation the payload's plan
    /// is made against. Skipped while the phone is locked: HealthKit cannot be read then.
    static func run(for types: Set<HealthDataType>) async -> Int {
        let (protected, active) = await MainActor.run {
            (UIApplication.shared.isProtectedDataAvailable, UIApplication.shared.applicationState == .active)
        }
        if protected {
            let budget = active ? DeletionTracking.foregroundBudget : DeletionTracking.backgroundBudget
            _ = await reader.read(targets: DeletionTracking.targets(for: types), budget: budget)
        }
        return await reader.store.generation
    }
}
