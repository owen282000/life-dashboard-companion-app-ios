import Foundation
import os

/// Deletion propagation, as the Android companion app does it (its issue #61).
///
/// A sync reads records, and a deleted record leaves nothing behind to read, so a receiver keeps
/// a record HealthKit no longer has. HealthKit never edits a record in place either: an app that
/// changes one deletes it and saves a new one under a new uuid, which without this leaves the
/// receiver holding both. HealthKit reports what was deleted to an anchored query that holds an
/// anchor; `DeletionReader` reads that, and the payload names the records in `deleted_records`.
///
/// This file holds the parts that are decidable without HealthKit, so they can be unit tested:
/// the payload shape, what a payload may carry, the time budgets and the types to read.

/// One deleted record, as it appears in the payload.
struct DeletedRecord: Codable, Hashable, Sendable {
    /// The payload key the record arrived under, e.g. "nutrition".
    let type: String
    /// The uuid the record was delivered with (`HKObject.uuid.uuidString`, uppercase).
    let uuid: String
}

/// A deletion waiting for a payload, stamped with the store generation that committed it.
struct PendingDeletion: Codable, Hashable, Sendable {
    let record: DeletedRecord
    let generation: Int
}

/// What one payload says about deletions.
struct DeletionSummary: Equatable, Sendable {
    var deleted: [DeletedRecord] = []
    /// Payload keys whose deletions this payload cannot vouch for.
    var unavailableTypes: [String] = []

    var isEmpty: Bool { deleted.isEmpty && unavailableTypes.isEmpty }
}

/// What a payload took from the pending store, so exactly that is removed once the payload is
/// delivered or in the outbox, and nothing another sync added in the meantime.
struct CarriedDeletions: Equatable, Sendable {
    var deletions: [PendingDeletion] = []
    /// Payload key to the generation it was named at.
    var unavailable: [String: Int] = [:]

    var isEmpty: Bool { deletions.isEmpty && unavailable.isEmpty }
}

/// The deletion part of one payload: what it says, what it carries, and which pending entries
/// turned out to be stale.
struct DeletionPlan: Equatable, Sendable {
    var summary = DeletionSummary()
    var carried = CarriedDeletions()
    var stale: [PendingDeletion] = []
}

/// One HealthKit sample type whose deletions are read for one data type, with its own anchor.
/// Active energy is read twice when both calorie types are on, once per payload key it can
/// arrive under, which keeps every target's state tied to exactly one key.
struct DeletionTarget: Hashable, Sendable {
    let dataType: HealthDataType
    let sampleTypeIdentifier: String

    var payloadKey: String { dataType.deletionPayloadKey }
    var key: String { "\(dataType.rawValue)|\(sampleTypeIdentifier)" }
}

enum DeletionTracking {

    // MARK: - Limits

    /// How long one target may take, and the whole step across every target. Warm, a query
    /// takes milliseconds; a cold HealthKit in a background wake can take much longer, and a
    /// hang is not an error, so without a bound the records behind the step would wait for it
    /// (Android 1.18.1). A target that does not fit keeps its anchor and is named in
    /// `deletions_unavailable` for that payload.
    static let perTargetTimeout: Duration = .seconds(5)
    static let foregroundBudget: Duration = .seconds(20)
    /// A background wake has about 30 seconds for the outbox, the step, the reads and the post.
    static let backgroundBudget: Duration = .seconds(8)

    /// Deleted objects per query. Never 0: `HKObjectQueryNoLimit` is 0.
    static let pageLimit = 1000
    /// Pages per target and sync; a burst larger than that continues next sync.
    static let maxPagesPerTarget = 20
    /// Deletions per payload; the rest waits for the next payload.
    static let maxDeletedPerPayload = 5000
    /// HealthKit may discard its record of a deletion at any time and gives no signal when it
    /// did. A target not read for this long is named once, as an estimate, not a HealthKit fact.
    static let staleAfter: TimeInterval = 7 * 24 * 3600
    /// Errors in a row after which a target starts over, so an anchor HealthKit keeps refusing
    /// is not named in every payload forever.
    static let maxConsecutiveErrors = 3

    // MARK: - Payload

    /// The deletion fields of a payload. Absent beats empty: no `deleted_records` says nothing
    /// was deleted, an empty array would say the app looked and found none.
    static func payloadFields(_ summary: DeletionSummary) -> [String: Any] {
        var fields: [String: Any] = [:]
        if !summary.deleted.isEmpty {
            fields["deleted_records"] = summary.deleted.map { ["type": $0.type, "uuid": $0.uuid] }
        }
        if !summary.unavailableTypes.isEmpty {
            fields["deletions_unavailable"] = summary.unavailableTypes
        }
        return fields
    }

    /// Every uuid a payload carries as a record, per payload key, sleep stages included: those
    /// records exist, so none of them may go out as deleted.
    static func recordUUIDs(in payload: [String: Any]) -> [String: Set<String>] {
        var ids: [String: Set<String>] = [:]
        for (key, value) in payload {
            guard let records = value as? [[String: Any]] else { continue }
            var found = Set<String>()
            for record in records {
                if let uuid = record["uuid"] as? String { found.insert(uuid) }
                for stage in record["stages"] as? [[String: Any]] ?? [] {
                    if let uuid = stage["uuid"] as? String { found.insert(uuid) }
                }
            }
            if !found.isEmpty { ids[key] = found }
        }
        return ids
    }

    /// Splits the pending deletions for one payload.
    ///
    /// A HealthKit uuid is never used again, so a pending deletion whose uuid was read as a
    /// record this sync means the read overlapped the deletion. When the deletion was committed
    /// before this sync's records read began (its generation is at most `readGeneration`), the
    /// read came after it and the record exists: the deletion is stale and dropped. When another
    /// sync committed it during the read, it is only kept out of this payload, which never names
    /// a uuid as a record and as deleted at once.
    static func plan(
        pending: [PendingDeletion],
        unavailable: [String: Int],
        readIds: [String: Set<String>],
        readGeneration: Int,
        maxDeleted: Int = maxDeletedPerPayload
    ) -> DeletionPlan {
        var plan = DeletionPlan()
        var seen = Set<DeletedRecord>()
        let ordered = pending.sorted { ($0.record.type, $0.record.uuid) < ($1.record.type, $1.record.uuid) }
        for entry in ordered {
            if readIds[entry.record.type]?.contains(entry.record.uuid) == true {
                if entry.generation <= readGeneration { plan.stale.append(entry) }
                continue
            }
            if seen.contains(entry.record) {
                plan.carried.deletions.append(entry)
                continue
            }
            guard plan.summary.deleted.count < maxDeleted else { continue }
            seen.insert(entry.record)
            plan.summary.deleted.append(entry.record)
            plan.carried.deletions.append(entry)
        }
        plan.summary.unavailableTypes = unavailable.keys.sorted()
        plan.carried.unavailable = unavailable
        return plan
    }

    // MARK: - Budgets and age

    /// How long the next query may take: the per-target limit, or what is left of the total
    /// when that is less, or zero once the total is spent.
    static func timeoutFor(
        elapsed: Duration,
        perTarget: Duration = perTargetTimeout,
        total: Duration
    ) -> Duration {
        max(.zero, min(perTarget, total - elapsed))
    }

    /// Whether a target went unread long enough that HealthKit may have dropped deletions. A
    /// target never read to the end is not stale: a start is not a gap. A read time in the
    /// future means the clock moved, and nothing about the gap is known.
    static func isStale(lastCompleteReadAt: Date?, now: Date) -> Bool {
        guard let last = lastCompleteReadAt else { return false }
        if last > now { return true }
        return now.timeIntervalSince(last) >= staleAfter
    }

    // MARK: - Targets

    /// The targets for the enabled types, in a stable order.
    static func targets(for types: Set<HealthDataType>) -> [DeletionTarget] {
        types.flatMap { type in
            type.deletionSampleTypes.map { DeletionTarget(dataType: type, sampleTypeIdentifier: $0.identifier) }
        }
        .sorted { $0.key < $1.key }
    }
}

// MARK: - Bounded calls

/// Runs one callback-style call with a deadline. Exactly one of the result, the timeout and the
/// task's cancellation resumes the caller; whatever arrives later is dropped, so a late HealthKit
/// answer can never hand back an anchor that then gets stored. `start` begins the call and returns
/// how to stop it, which only the timeout and the cancellation use.
enum BoundedCall {
    struct TimedOut: Error {}

    typealias Scheduler = @Sendable (Duration, @escaping @Sendable () -> Void) -> Void

    static let afterDelay: Scheduler = { delay, work in
        let (seconds, attoseconds) = delay.components
        let interval = Double(seconds) + Double(attoseconds) / 1e18
        DispatchQueue.global().asyncAfter(deadline: .now() + interval, execute: work)
    }

    static func run<Value: Sendable>(
        timeout: Duration,
        schedule: Scheduler = afterDelay,
        start: @escaping @Sendable (@escaping @Sendable (Result<Value, Error>) -> Void) -> (@Sendable () -> Void)
    ) async throws -> Value {
        try Task.checkCancellation()
        let box = OneShot<Value>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard box.install(continuation) else { return }
                let stop = start { result in _ = box.finish(result) }
                box.setStop(stop)
                schedule(timeout) {
                    if box.finish(.failure(TimedOut())) { box.stopCall() }
                }
            }
        } onCancel: {
            if box.finish(.failure(CancellationError())) { box.stopCall() }
        }
    }
}

/// The one-time handoff behind `BoundedCall`: the first result wins, later ones are ignored.
final class OneShot<Value: Sendable>: @unchecked Sendable {
    private enum Phase {
        case idle
        case early(Result<Value, Error>)
        case waiting(CheckedContinuation<Value, Error>)
        case finished
    }

    private struct State {
        var phase: Phase = .idle
        var stop: (@Sendable () -> Void)?
        var stopWanted = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    /// Hands over the continuation. False when a result (a cancellation that came first) has
    /// already resumed it, in which case the call must not start.
    func install(_ continuation: CheckedContinuation<Value, Error>) -> Bool {
        let early: Result<Value, Error>? = state.withLock { state in
            if case .early(let result) = state.phase {
                state.phase = .finished
                return result
            }
            state.phase = .waiting(continuation)
            return nil
        }
        guard let early else { return true }
        continuation.resume(with: early)
        return false
    }

    /// Resumes the caller with `result` if nothing did yet. True when this call won.
    @discardableResult
    func finish(_ result: Result<Value, Error>) -> Bool {
        let continuation: CheckedContinuation<Value, Error>?? = state.withLock { state in
            switch state.phase {
            case .idle:
                state.phase = .early(result)
                return .some(nil)
            case .waiting(let continuation):
                state.phase = .finished
                return .some(continuation)
            case .early, .finished:
                return nil
            }
        }
        guard let won = continuation else { return false }
        won?.resume(with: result)
        return true
    }

    func setStop(_ stop: @escaping @Sendable () -> Void) {
        let runNow = state.withLock { state -> Bool in
            state.stop = stop
            return state.stopWanted
        }
        if runNow { stop() }
    }

    /// Stops the call, now or as soon as its stop is known; at most once.
    func stopCall() {
        let stop = state.withLock { state -> (@Sendable () -> Void)? in
            guard !state.stopWanted else { return nil }
            state.stopWanted = true
            return state.stop
        }
        stop?()
    }
}
