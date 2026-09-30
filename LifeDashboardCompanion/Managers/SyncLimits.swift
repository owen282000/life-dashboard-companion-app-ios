import Foundation

enum SyncLimits {
    /// Max records delivered per sync for a type, to bound payload size and memory.
    /// Mirrors the Android companion app's limits. Batches are capped oldest-first so
    /// later syncs catch up without skipping records.
    static func maxRecordsPerSync(for type: HealthDataType) -> Int {
        switch type {
        case .heartRate, .steps:
            return 1000
        case .heartRateVariability, .respiratoryRate:
            return 500
        default:
            return 200
        }
    }

    /// Caps records to at most `limit`, keeping the OLDEST ones. Every dropped record is
    /// newer than every kept one, so a later sync can pick up where this one left off.
    static func capOldestFirst<T>(_ records: [T], limit: Int, timeOf: (T) -> Date) -> [T] {
        guard records.count > limit else { return records }
        return Array(records.sorted { timeOf($0) < timeOf($1) }.prefix(limit))
    }

    /// Where the next read of a type has to stop so that it stays under `limit`, given the
    /// start dates a probe found from `start` on (the first `limit` of each HealthKit sample
    /// type the payload type reads, in any order). Reads are half-open, `[start, end)`, so the
    /// slice ends AT a probed sample and that sample opens the next slice. The slice is cut a
    /// tenth below the limit, so a few samples written between the probe and the read still
    /// fit. `exact` is false only when that many samples share the very first timestamp: such
    /// a slice cannot be split any further, and a read of it drops what is past the cap.
    static func sliceEnd(
        probedStartDates: [Date],
        limit: Int,
        from start: Date,
        to end: Date
    ) -> (end: Date, exact: Bool) {
        let fill = limit - limit / 10
        guard fill > 0, probedStartDates.count >= fill else { return (end, true) }
        let boundary = probedStartDates.sorted()[fill - 1]
        guard boundary > start else {
            // A millisecond is below every timestamp HealthKit apps write, so this moves
            // past the tie without reaching the next distinct sample in practice.
            return (min(start.addingTimeInterval(0.001), end), false)
        }
        return (min(boundary, end), true)
    }

    /// Where an incremental read of a type starts: at the catch-up cursor the last read left,
    /// an hour before the earliest sample added since the anchors, or at the lookback start of
    /// a sample type read for the first time, whichever is earliest. Nil when none applies.
    static func incrementalReadStart(cursor: Date?, earliestAdded: [Date], firstReads: [Date]) -> Date? {
        ([cursor].compactMap { $0 } + earliestAdded.map { $0.addingTimeInterval(-3600) } + firstReads).min()
    }

    /// The catch-up cursor a read that stopped at `sliceEnd` leaves: nil once it reached `now`.
    static func catchUpCursor(afterSliceEndingAt sliceEnd: Date, now: Date) -> Date? {
        sliceEnd < now ? sliceEnd : nil
    }
}
