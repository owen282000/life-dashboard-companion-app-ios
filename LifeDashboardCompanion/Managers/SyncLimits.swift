import Foundation

enum SyncLimits {
    /// Max records delivered per sync for a type, to bound payload size and memory.
    /// Mirrors the Android companion app's limits. Batches are capped oldest-first so
    /// later syncs catch up without skipping records. Total calories reads active and resting
    /// energy together, a sample a minute each from an Apple Watch, so it gets the dense
    /// types' cap, as on Android.
    static func maxRecordsPerSync(for type: HealthDataType) -> Int {
        switch type {
        case .heartRate, .steps, .totalCalories:
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

    /// Where a read has to start to hold the newest records of a type under `limit`, given
    /// the start dates a probe found newest first (the first `limit` of each HealthKit sample
    /// type the payload type reads). Nil when the probe found fewer than a read may hold, so a
    /// read of the whole range holds the newest ones already. Like `sliceEnd` it leaves a tenth
    /// of the cap for samples that share the boundary or arrive in between.
    static func tailStart(probedStartDates: [Date], limit: Int) -> Date? {
        let fill = limit - limit / 10
        guard fill > 0, probedStartDates.count >= fill else { return nil }
        return probedStartDates.sorted(by: >)[fill - 1]
    }

    /// Where the time read of an incremental sync starts: at the catch-up cursor the last read
    /// left, or at the lookback start of a sample type read for the first time, whichever is
    /// earlier. Nil when neither applies: the sync then reads only what the anchors report.
    static func timeReadStart(cursor: Date?, firstRead: Date?) -> Date? {
        [cursor, firstRead].compactMap { $0 }.min()
    }

    /// The catch-up cursor a read that stopped at `sliceEnd` leaves: nil once it reached `now`.
    static func catchUpCursor(afterSliceEndingAt sliceEnd: Date, now: Date) -> Date? {
        sliceEnd < now ? sliceEnd : nil
    }
}

/// A sample an anchored query reported as added since the last sync.
struct AddedSample: Hashable, Sendable {
    let uuid: UUID
    let start: Date
    let end: Date
}

/// How an incremental sync reads a type, apart from HealthKit so it can be tested.
///
/// The anchors report the samples added since the last sync, and only those are sent. They
/// used to be the start of a read by time, from an hour before the earliest of them to now,
/// so one weight entered for last year, or an import, sent every record of the type since
/// then again. The time read is still there for what the anchors cannot report: the lookback
/// week of a type synced for the first time, continued through the catch-up cursor.
enum IncrementalRead {
    /// Added samples read in one sync, for all the sample types a payload type combines
    /// together, since its reader caps them together (total calories caps active and resting
    /// energy as one): a page never holds more than one payload can carry. What is past it
    /// stays behind the anchor for the next sync.
    ///
    /// While the type is catching up by time, its first week or the rest past a cursor, that
    /// read takes up to nine tenths of the cap (see `SyncLimits.sliceEnd`), and the page gets
    /// the tenth left, so one payload still carries no more than the cap of the type.
    static func pageBudget(for type: HealthDataType, catchingUp: Bool = false) -> Int {
        let cap = SyncLimits.maxRecordsPerSync(for: type)
        return max(1, catchingUp ? cap / 10 : cap)
    }

    /// `items` starting at `offset`, wrapping around: the order a budget is spent in.
    static func rotated<T>(_ items: [T], by offset: Int) -> [T] {
        guard !items.isEmpty else { return items }
        let start = ((offset % items.count) + items.count) % items.count
        return Array(items[start...] + items[..<start])
    }

    /// The added samples in groups that lie within `gap` of each other, as the stretches of
    /// time they span; at most `maxCount`, joined across the smallest gaps first.
    static func spans(of added: [AddedSample], gap: TimeInterval, maxCount: Int) -> [DateInterval] {
        let starts = added.map(\.start).sorted()
        guard let first = starts.first else { return [] }
        let gaps = zip(starts, starts.dropFirst()).enumerated()
            .map { (index: $0.offset, length: $0.element.1.timeIntervalSince($0.element.0)) }
            .filter { $0.length > gap }
        let cuts = Set(gaps.sorted { $0.length > $1.length }.prefix(max(0, maxCount - 1)).map(\.index))
        var spans: [DateInterval] = []
        var spanStart = first
        for (index, start) in starts.enumerated() where cuts.contains(index) {
            spans.append(DateInterval(start: spanStart, end: start))
            spanStart = starts[index + 1]
        }
        spans.append(DateInterval(start: spanStart, end: starts[starts.count - 1]))
        return spans
    }

    /// The records whose uuid is in `ids`; keys left without a record are dropped.
    static func records(_ pairs: [(String, Any)]?, withUuidIn ids: Set<UUID>) -> [(String, Any)]? {
        let wanted = Set(ids.map(\.uuidString))
        let kept = (pairs ?? []).compactMap { key, value -> (String, Any)? in
            let records = (value as? [[String: Any]] ?? []).filter { ($0["uuid"] as? String).map(wanted.contains) ?? false }
            return records.isEmpty ? nil : (key, records as Any)
        }
        return kept.isEmpty ? nil : kept
    }

    /// Where the time read starts and which added samples go by uuid, from the cursor, the
    /// lookback start of a first read, the added samples and the time of the read.
    static func plan(cursor: Date?, firstRead: Date?, added: [AddedSample], now: Date) -> (timeReadStart: Date?, byUuid: [AddedSample]) {
        let start = SyncLimits.timeReadStart(cursor: cursor, firstRead: firstRead)
        return (start, byUuid(added, timeReadFrom: start, now: now))
    }

    /// The added samples to read by uuid: those the time read does not reach. From its start
    /// on, the time read covers everything up to now, in this sync or through the cursor in
    /// the next ones, so an added sample there would go out twice.
    static func byUuid(_ added: [AddedSample], timeReadFrom start: Date?, now: Date) -> [AddedSample] {
        guard let start else { return added }
        return added.filter { $0.start < start || $0.start >= now }
    }

    /// Where a type whose records are built from several samples, sleep sessions from stages
    /// and menstruation periods from flow days, is read around its added samples. Samples
    /// closer than `gap` belong to the same session and form one group; each group is widened
    /// by `padding` on both sides, so the session it belongs to is read whole, neighbours
    /// included. Groups are not joined further, so a window never grows past its own group,
    /// however many nights an import spreads its samples over.
    static func sessionWindows(for added: [AddedSample], gap: TimeInterval, padding: TimeInterval) -> [DateInterval] {
        var groups: [DateInterval] = []
        for sample in added.sorted(by: { $0.start < $1.start }) {
            let end = max(sample.end, sample.start)
            if let last = groups.last, sample.start <= last.end.addingTimeInterval(gap) {
                groups[groups.count - 1] = DateInterval(start: last.start, end: max(last.end, end))
            } else {
                groups.append(DateInterval(start: sample.start, end: end))
            }
        }
        return groups.map {
            DateInterval(start: $0.start.addingTimeInterval(-padding), end: $0.end.addingTimeInterval(padding))
        }
    }

    /// The sleep sessions to send: those holding an added stage. A session read around one is
    /// sent whole, its earlier stages included, under the uuid derived from its first stage.
    static func sessions(_ sessions: [[String: Any]], holding added: Set<UUID>) -> [[String: Any]] {
        let ids = Set(added.map(\.uuidString))
        return sessions.filter { session in
            (session["stages"] as? [[String: Any]] ?? []).contains { ($0["uuid"] as? String).map(ids.contains) ?? false }
        }
    }

    /// The menstruation periods to send: those a newly added flow day falls in. The period's
    /// times are whole seconds, so its end gets a second more for a flow day that starts and
    /// ends at the same moment with a fraction of a second.
    static func periods(_ periods: [[String: Any]], holding added: [AddedSample]) -> [[String: Any]] {
        periods.filter { period in
            guard let start = (period["start_time"] as? String).flatMap(BackfillController.parseDate),
                  let end = (period["end_time"] as? String).flatMap(BackfillController.parseDate) else { return false }
            return added.contains { $0.start >= start && $0.start < end.addingTimeInterval(1) }
        }
    }

    /// The records of the time read and the uuid read together, each record once. A record is
    /// known by its uuid; a period, which has none, by its start and end.
    static func merge(_ first: [(String, Any)]?, _ second: [(String, Any)]?) -> [(String, Any)]? {
        guard let second else { return first }
        guard let first else { return second }
        var keys: [String] = []
        var records: [String: [[String: Any]]] = [:]
        for (key, value) in first + second {
            if records[key] == nil { keys.append(key) }
            records[key, default: []] += value as? [[String: Any]] ?? []
        }
        return keys.map { key in
            var seen = Set<String>()
            let unique = (records[key] ?? []).filter { seen.insert(identity(of: $0)).inserted }
            return (key, unique as Any)
        }
    }

    private static func identity(of record: [String: Any]) -> String {
        if let uuid = record["uuid"] as? String { return uuid }
        return ["start_time", "end_time", "time"].map { record[$0] as? String ?? "" }.joined(separator: "|")
    }

    /// Whether the records read for a type hold its newest sample, so MQTT can publish them as
    /// the current value. A sensor shows the latest record it is given, and a back-dated
    /// entry would otherwise replace today's value with last year's.
    /// `newestInStore` is the newest sample HealthKit holds up to `now`; a sample dated after
    /// `now` is not a current value either way.
    static func holdsNewest(behind: Bool, timeReadReachedNow: Bool, byUuidStarts: [Date], newestInStore: Date?, now: Date) -> Bool {
        if behind { return false }
        if timeReadReachedNow { return true }
        guard let newestInStore else { return true }
        guard let newestRead = byUuidStarts.filter({ $0 <= now }).max() else { return false }
        return newestRead >= newestInStore
    }
}
