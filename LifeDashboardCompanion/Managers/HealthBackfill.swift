import Foundation
import OSLog

// The backfill sends a stretch of HealthKit history to the webhooks, the way the Android app's
// Backfill does: 3-day windows, oldest first, each drained in chunks that stay under the
// per-type caps. Everything in this file is free of HealthKit and UIKit, so the whole loop is
// tested with a fake reader and a fake webhook; BackfillController wires in the real ones.

// MARK: - Plan

enum BackfillPlan {
    /// Android's window: three days of 86,400 seconds, not calendar days.
    static let windowLength: TimeInterval = 3 * 86_400
    /// Read and deliver passes per window. The cursors move forward on every pass, so this only
    /// bounds the time a window can take, as Android's MAX_PASSES_PER_BACKFILL_WINDOW does.
    static let maxPassesPerWindow = 400
    /// How far around a window sleep and cycle data are read, so a night or a period that
    /// crosses a window bound is built whole and sent once, by the window that owns it.
    static let sleepPadding: TimeInterval = 86_400
    static let periodPadding: TimeInterval = 14 * 86_400

    /// The range for a backfill of `days` started at `now`. The end is floored to a whole
    /// second so `window_end` in the payload, which has no fractions, is the real bound.
    static func range(days: Int, now: Date, earliestPermitted: Date = .distantPast) -> DateInterval {
        let end = Date(timeIntervalSinceReferenceDate: now.timeIntervalSinceReferenceDate.rounded(.down))
        let start = max(end.addingTimeInterval(-TimeInterval(days) * 86_400), earliestPermitted)
        return DateInterval(start: min(start, end), end: end)
    }

    static func windowCount(of range: DateInterval) -> Int {
        guard range.duration > 0 else { return 0 }
        return Int((range.duration / windowLength).rounded(.up))
    }

    /// Window `index`, oldest first; the last one ends at the range end and may be shorter.
    static func window(_ index: Int, of range: DateInterval) -> DateInterval {
        let start = range.start.addingTimeInterval(TimeInterval(index) * windowLength)
        return DateInterval(start: start, end: min(start.addingTimeInterval(windowLength), range.end))
    }

    /// Whether a sleep session ending at `end` belongs to `window`. A session belongs to the
    /// window it ends in; one that ends within an hour of the range end may still be going on
    /// and is left to the regular sync, which reads the last week anyway.
    static func ownsSession(endingAt end: Date, window: DateInterval, rangeEnd: Date) -> Bool {
        guard end >= window.start, end < window.end else { return false }
        return window.end < rangeEnd || end <= rangeEnd.addingTimeInterval(-SleepSessionBuilder.sessionGap)
    }

    /// Whether a menstruation period starting at `start` belongs to `window`.
    static func ownsPeriod(startingAt start: Date, window: DateInterval) -> Bool {
        start >= window.start && start < window.end
    }
}

// MARK: - Job

/// The persisted state of a backfill. It is saved when a window has been delivered in full,
/// so a resume starts at the first window that was not; at most one window goes out twice,
/// and the receiver deduplicates its records on their uuid.
struct BackfillJob: Codable, Equatable {
    enum Status: String, Codable {
        case running, paused, failed, done
    }

    enum PauseReason: String, Codable {
        /// The user tapped Pause.
        case user
        /// iOS was about to suspend the app after the user left it.
        case background
        /// The iPhone locked; HealthKit cannot be read then.
        case locked
        /// The app was closed or crashed while the backfill ran.
        case closed
        /// A delivery or read was cut off by the run being stopped.
        case interrupted
        /// iOS ended the background task, or the user stopped it from the system progress UI.
        case system
    }

    enum Failure: Codable, Equatable {
        case delivery
        case read(type: String)
    }

    var version = 1
    let id: UUID
    let days: Int
    let rangeStart: Date
    let rangeEnd: Date
    var nextWindow = 0
    var recordsSent = 0
    /// Windows that could not be sent in full: a pile of samples at one instant beyond the cap,
    /// or more passes than a window may take.
    var truncatedWindows = 0
    var status = Status.running
    var pauseReason: PauseReason?
    var failure: Failure?
    var updatedAt: Date

    init(days: Int, range: DateInterval, now: Date = Date()) {
        self.id = UUID()
        self.days = days
        self.rangeStart = range.start
        self.rangeEnd = range.end
        self.updatedAt = now
    }

    var range: DateInterval { DateInterval(start: rangeStart, end: rangeEnd) }
    var windowCount: Int { BackfillPlan.windowCount(of: range) }
    var isFinished: Bool { status == .done }

    func paused(_ reason: PauseReason, at now: Date = Date()) -> BackfillJob {
        var job = self
        job.status = .paused
        job.pauseReason = reason
        job.failure = nil
        job.updatedAt = now
        return job
    }

    func failed(_ failure: Failure, at now: Date = Date()) -> BackfillJob {
        var job = self
        job.status = .failed
        job.pauseReason = nil
        job.failure = failure
        job.updatedAt = now
        return job
    }
}

/// Keeps the job in UserDefaults: a few numbers and dates, and no health data.
struct BackfillJobStore {
    static let key = "backfill_job"
    let defaults: UserDefaults

    func load() -> BackfillJob? {
        guard let data = defaults.data(forKey: BackfillJobStore.key) else { return nil }
        guard let job = try? JSONDecoder().decode(BackfillJob.self, from: data) else {
            // From a newer or broken version: start over rather than guess.
            defaults.removeObject(forKey: BackfillJobStore.key)
            return nil
        }
        return job
    }

    func save(_ job: BackfillJob) {
        guard let data = try? JSONEncoder().encode(job) else { return }
        defaults.set(data, forKey: BackfillJobStore.key)
    }

    func clear() {
        defaults.removeObject(forKey: BackfillJobStore.key)
    }
}

enum BackfillResume {
    /// A pause the user did not ask for is picked up again when the app comes back, for a day.
    static let autoResumeWindow: TimeInterval = 24 * 3600

    static func shouldAutoResume(_ job: BackfillJob, now: Date, hasWebhook: Bool, hasTypes: Bool) -> Bool {
        guard job.status == .paused, hasWebhook, hasTypes,
              let reason = job.pauseReason,
              now.timeIntervalSince(job.updatedAt) < autoResumeWindow else { return false }
        switch reason {
        case .background, .locked, .closed, .interrupted:
            return true
        case .user, .system:
            return false
        }
    }
}

// MARK: - Payload

enum BackfillPayload {
    /// The body of one backfill chunk. Android's backfill fields, with `window_complete` always
    /// false: HealthKit does not tell an app that a type's read access was denied, it returns
    /// nothing, and it cannot tell whether an iCloud restore of Health is still coming in. A
    /// receiver may drop records it holds in a window marked complete, so iOS never claims it.
    static func body(
        records: [(String, Any)],
        window: DateInterval,
        extras: [String: Any],
        appVersion: String,
        now: Date
    ) -> Data? {
        var payload: [String: Any] = extras
        for (key, value) in records {
            payload[key] = value
        }
        payload["timestamp"] = now.iso8601String
        payload["app_version"] = appVersion
        payload["source"] = "healthkit_ios"
        payload["backfill"] = true
        payload["window_start"] = window.start.iso8601String
        payload["window_end"] = window.end.iso8601String
        payload["window_complete"] = false
        return try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    }

    static func recordCount(_ records: [(String, Any)]) -> Int {
        records.reduce(0) { $0 + (($1.1 as? [Any])?.count ?? 0) }
    }
}

// MARK: - Engine

/// A slice of one type's records, up to where the next one starts. @unchecked Sendable: the
/// records are JSON value types built fresh for this slice, like HealthKitManager's fragments.
struct BackfillSlice: @unchecked Sendable {
    let records: [(String, Any)]
    /// Where the next slice of the type starts; the window end when the type is done.
    let end: Date
    /// False when the slice could not be read in full (see `SyncLimits.sliceEnd`).
    let exact: Bool
}

enum BackfillReadError: Error {
    case locked
}

protocol BackfillReading: Sendable {
    /// False while HealthKit cannot be read (the iPhone is locked).
    func canRead() async -> Bool
    /// The next slice of `type` from `cursor` on, inside `window`. Throws
    /// `BackfillReadError.locked` when the store became unreadable.
    func readSlice(_ type: HealthDataType, from cursor: Date, window: DateInterval, rangeEnd: Date) async throws -> BackfillSlice
}

protocol BackfillDelivering: Sendable {
    func deliver(_ body: Data, recordCount: Int) async -> Bool
}

/// Progress for the screen: windows done out of the total, and records sent in this job.
struct BackfillProgress: Equatable, Sendable {
    let windowsDone: Int
    let windowCount: Int
    let recordsSent: Int
}

/// Extra top-level keys for every payload of a window, asked for once per window: the seam
/// for `daily_totals`, which a backfill sends for every day of its window, as Android does.
/// @unchecked Sendable: JSON value types built fresh per window.
struct BackfillExtras: @unchecked Sendable {
    let fields: [String: Any]
    static let none = BackfillExtras(fields: [:])
}

struct BackfillEngine: Sendable {
    let reader: BackfillReading
    let sink: BackfillDelivering
    let appVersion: String
    /// The enabled types, asked for at the start of every window.
    var enabledTypes: @Sendable () async -> [HealthDataType]
    var windowExtras: @Sendable (DateInterval) async -> BackfillExtras = { _ in .none }
    /// Asked between passes; a reason ends the run with the job paused for it.
    var shouldStop: @Sendable () async -> BackfillJob.PauseReason? = { nil }
    var onProgress: @Sendable (BackfillProgress) async -> Void = { _ in }
    /// Called with the job once a window was delivered in full, to be saved.
    var onWindowDone: @Sendable (BackfillJob, _ windowRecords: Int) async -> Void = { _, _ in }
    var now: @Sendable () -> Date = { Date() }

    private static let logger = Logger(subsystem: "com.owen282000.lifedashboard", category: "Backfill")

    /// Runs `job` from its next window to the end, or until it stops, and returns the job in
    /// the state it stopped in: done, paused with a reason, or failed.
    func run(_ start: BackfillJob) async -> BackfillJob {
        var job = start
        job.status = .running
        job.pauseReason = nil
        job.failure = nil
        let range = job.range
        let windowCount = job.windowCount

        while job.nextWindow < windowCount {
            if let reason = await shouldStop() { return job.paused(reason, at: now()) }
            let window = BackfillPlan.window(job.nextWindow, of: range)
            let outcome = await drain(window, of: job, rangeEnd: range.end)
            switch outcome {
            case .stopped(let stopped):
                return stopped
            case .delivered(let records, let truncated):
                job.nextWindow += 1
                job.recordsSent += records
                if truncated { job.truncatedWindows += 1 }
                job.updatedAt = now()
                await onWindowDone(job, records)
            }
        }
        job.status = .done
        job.updatedAt = now()
        return job
    }

    private enum WindowOutcome {
        case delivered(records: Int, truncated: Bool)
        case stopped(BackfillJob)
    }

    /// Sends one window: each pass reads the next slice of every type still draining and posts
    /// them as one payload. A window with nothing in it still sends one payload, so a receiver
    /// sees that it was covered.
    private func drain(_ window: DateInterval, of job: BackfillJob, rangeEnd: Date) async -> WindowOutcome {
        let types = await enabledTypes().sorted { $0.rawValue < $1.rawValue }
        let extras = await windowExtras(window)
        var cursors = Dictionary(uniqueKeysWithValues: types.map { ($0, window.start) })
        var records = 0
        var sent = 0
        var truncated = false

        for pass in 1...BackfillPlan.maxPassesPerWindow {
            if pass > 1, let reason = await shouldStop() { return .stopped(job.paused(reason, at: now())) }
            guard await reader.canRead() else { return .stopped(job.paused(.locked, at: now())) }

            var chunk: [(String, Any)] = []
            var next = cursors
            for type in types {
                guard let cursor = cursors[type] else { continue }
                let slice: BackfillSlice
                do {
                    slice = try await reader.readSlice(type, from: cursor, window: window, rangeEnd: rangeEnd)
                } catch BackfillReadError.locked {
                    return .stopped(job.paused(.locked, at: now()))
                } catch {
                    if Task.isCancelled { return .stopped(job.paused(.interrupted, at: now())) }
                    Self.logger.error("Backfill read of \(type.rawValue) failed: \(error.localizedDescription)")
                    return .stopped(job.failed(.read(type: type.displayName), at: now()))
                }
                chunk += slice.records
                if !slice.exact {
                    truncated = true
                    Self.logger.error("Backfill window from \(window.start.iso8601String): more \(type.rawValue) samples at one instant than one read holds")
                }
                next[type] = slice.end >= window.end ? nil : slice.end
            }

            let count = BackfillPayload.recordCount(chunk)
            if count > 0 || sent == 0 {
                guard let body = BackfillPayload.body(
                    records: chunk, window: window, extras: extras.fields, appVersion: appVersion, now: now()
                ) else {
                    return .stopped(job.failed(.delivery, at: now()))
                }
                guard await sink.deliver(body, recordCount: count) else {
                    if Task.isCancelled { return .stopped(job.paused(.interrupted, at: now())) }
                    return .stopped(job.failed(.delivery, at: now()))
                }
                sent += 1
                records += count
                await onProgress(BackfillProgress(
                    windowsDone: job.nextWindow, windowCount: job.windowCount, recordsSent: job.recordsSent + records
                ))
            }

            cursors = next
            if cursors.isEmpty { return .delivered(records: records, truncated: truncated) }
        }
        Self.logger.error("Backfill window from \(window.start.iso8601String) needs more than \(BackfillPlan.maxPassesPerWindow) passes")
        return .delivered(records: records, truncated: true)
    }
}
