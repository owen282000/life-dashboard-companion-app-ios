import Foundation

// Data resolution per type, the Android app's SeriesResolution, ResolutionPayload and
// ResolutionApplier in one file. A Watch writes a heart rate sample every few seconds during a
// workout, records no dashboard reads one by one; bucketing turns them into one value per
// minute, or per hour, before they reach a webhook.
//
// Everything here works on the payload the sync has already built, after the read and before
// the post, so anchors, catch-up cursors, the retry queue and MQTT are untouched: MQTT gets
// the raw records, and a queued payload is already bucketed. Only the carry (the samples of
// windows still filling) is stored, together with the anchors (see AnchorCommit).

/// How densely a type is reported. Raw is the default and changes nothing, so a receiver
/// keeps seeing exactly what it saw before. The raw values are Android's enum names, which the
/// settings backup and the stored setting use.
enum SeriesResolution: String, CaseIterable, Codable, Sendable {
    case raw = "RAW"
    case oneMinute = "ONE_MINUTE"
    case fiveMinutes = "FIVE_MINUTES"
    case fifteenMinutes = "FIFTEEN_MINUTES"
    case hourly = "HOURLY"

    /// The window in seconds; nil at raw.
    var bucket: TimeInterval? {
        switch self {
        case .raw: return nil
        case .oneMinute: return 60
        case .fiveMinutes: return 300
        case .fifteenMinutes: return 900
        case .hourly: return 3600
        }
    }

    /// How the payload names it: a duration a receiver can parse, not an enum name.
    var payloadName: String {
        switch self {
        case .raw: return "raw"
        case .oneMinute: return "1m"
        case .fiveMinutes: return "5m"
        case .fifteenMinutes: return "15m"
        case .hourly: return "1h"
        }
    }

    /// A stored name, raw for anything unknown, so a partly written or newer value degrades
    /// to every record rather than to silently averaged ones.
    static func from(_ name: String?) -> SeriesResolution {
        name.flatMap(SeriesResolution.init(rawValue:)) ?? .raw
    }

    /// Bucketing is lossy, so it is offered, never applied on anyone's behalf.
    static let defaultResolution = SeriesResolution.raw
}

/// What a window does to a type's values: a measurement is averaged with its range kept, a
/// quantity is summed. Every other type is a one-off event (a weight, a workout, a meal), or
/// sleep, whose stages are the data, and has no resolution.
enum ResolutionFamily: CaseIterable, Sendable {
    case sampled
    case accumulated

    static func of(_ type: HealthDataType) -> ResolutionFamily? {
        switch type {
        // Android also lists skin temperature, which HealthKit does not offer as a delta.
        case .heartRate, .heartRateVariability, .oxygenSaturation, .respiratoryRate:
            return .sampled
        case .steps, .distance, .activeCalories, .totalCalories:
            return .accumulated
        default:
            return nil
        }
    }

    /// Every type the setting applies to, in the order the screen lists them.
    static var configurableTypes: [HealthDataType] {
        HealthDataType.allCases.filter { of($0) != nil }
    }
}

extension HealthDataType {
    /// The record fields a bucket is built from: the moment the record belongs to (an interval
    /// record counts whole, in the window it starts in, as on Android) and its value.
    var seriesFields: (time: String, value: String)? {
        switch self {
        case .heartRate: return ("time", "bpm")
        case .heartRateVariability: return ("time", "heart_rate_variability_millis")
        case .oxygenSaturation: return ("time", "percentage")
        case .respiratoryRate: return ("time", "rate")
        case .steps: return ("start_time", "count")
        case .distance: return ("start_time", "meters")
        case .activeCalories, .totalCalories: return ("start_time", "calories")
        default: return nil
        }
    }
}

/// One measurement reduced to what bucketing needs, so the samples of a window that is still
/// filling can wait for the next sync. Unlike on Android it keeps the uuid, so a sample read
/// again counts once and a deleted one can leave the carry, and an interval record's end, so a
/// type set back to raw sends what it held as the records they were.
struct CarriedSample: Codable, Equatable, Sendable {
    let time: Date
    let value: Double
    var source: String?
    var uuid: String?
    var end: Date?
}

/// One window of a series and what its samples came to.
struct Bucket: Equatable, Sendable {
    let start: Date
    let end: Date
    let mean: Double
    let minimum: Double
    let maximum: Double
    let total: Double
    let sampleCount: Int
    /// Sources that contributed, so a window mixing iPhone and Watch is still traceable.
    let sources: [String]
    /// True when the bucket holds every sample HealthKit had in the window when it was built,
    /// not only the ones a sync read as new: a receiver replaces a stored window with it
    /// instead of adding to it (P2-16).
    var complete = false
}

/// Every sample of one type HealthKit holds in `[from, to)`, read to build the windows a sync
/// is about to send whole (P2-16).
struct WholeContent: Sendable {
    let samples: [CarriedSample]
    let from: Date
    let to: Date

    /// Whether the window `[start, end)` lies wholly inside what was read.
    func covers(_ start: Date, _ end: Date) -> Bool { start >= from && end <= to }
}

enum SeriesBucketing {
    /// Groups `samples` into windows of `resolution`, aligned to the epoch rather than to the
    /// first sample, so two syncs produce windows that line up. Empty at raw.
    static func bucket(_ samples: [CarriedSample], resolution: SeriesResolution) -> [Bucket] {
        guard let window = resolution.bucket, !samples.isEmpty else { return [] }
        let windowMillis = Int64(window * 1000)
        let grouped = Dictionary(grouping: samples) { alignDown($0.time, windowMillis: windowMillis) }
        return grouped.keys.sorted().map { startMillis in
            let inBucket = grouped[startMillis] ?? []
            let values = inBucket.map(\.value)
            let total = values.reduce(0, +)
            return Bucket(
                start: Date(timeIntervalSince1970: Double(startMillis) / 1000),
                end: Date(timeIntervalSince1970: Double(startMillis + windowMillis) / 1000),
                mean: total / Double(values.count),
                minimum: values.min() ?? 0,
                maximum: values.max() ?? 0,
                total: total,
                sampleCount: values.count,
                sources: Array(Set(inBucket.compactMap(\.source).filter { !$0.isEmpty })).sorted()
            )
        }
    }

    /// The buckets complete at `boundary`, and where the first incomplete one begins (nil when
    /// every bucket is closed). A bucket that ends exactly at the boundary is closed.
    static func splitClosed(_ buckets: [Bucket], boundary: Date) -> (closed: [Bucket], openFrom: Date?) {
        (buckets.filter { $0.end <= boundary }, buckets.first { $0.end > boundary }?.start)
    }

    /// The first bucket bound at or after `time`.
    static func alignUp(_ time: Date, resolution: SeriesResolution) -> Date {
        guard let window = resolution.bucket else { return time }
        let windowMillis = Int64(window * 1000)
        let millis = Int64((time.timeIntervalSince1970 * 1000).rounded(.up))
        let down = alignDown(Date(timeIntervalSince1970: Double(millis) / 1000), windowMillis: windowMillis)
        return Date(timeIntervalSince1970: Double(down == millis ? down : down + windowMillis) / 1000)
    }

    /// Epoch milliseconds floored to the window, also before 1970.
    private static func alignDown(_ time: Date, windowMillis: Int64) -> Int64 {
        let millis = Int64((time.timeIntervalSince1970 * 1000).rounded(.down))
        let remainder = millis % windowMillis
        return millis - (remainder < 0 ? remainder + windowMillis : remainder)
    }
}

/// The JSON a receiver sees, key for key Android's ResolutionPayload. A bucketed array replaces
/// the raw one under the same key, and its objects never carry the raw field name, so
/// `"bucket_start" in obj` tells the two shapes apart.
enum ResolutionPayload {
    static let resolutionsKey = "_resolutions"

    /// `decimals` are those of the records' value field (PayloadJSON), which the total, min and
    /// max keep, so a sum of 2-decimal calories is not sent as 129.91000000000003. The average
    /// keeps its shortest exact form, as Android writes it.
    static func bucketJSON(_ bucket: Bucket, family: ResolutionFamily, decimals: Int? = nil) -> [String: Any] {
        var json: [String: Any] = [
            "bucket_start": bucket.start.iso8601String,
            "bucket_end": bucket.end.iso8601String,
            "sample_count": bucket.sampleCount
        ]
        switch family {
        case .accumulated:
            json["total"] = number(bucket.total, decimals: decimals)
        case .sampled:
            json["avg"] = number(bucket.mean)
            json["min"] = number(bucket.minimum, decimals: decimals)
            json["max"] = number(bucket.maximum, decimals: decimals)
        }
        if !bucket.sources.isEmpty { json["sources"] = bucket.sources }
        // Only when true: a bucket without it is one a receiver combines with what it holds,
        // which is how every bucket before P2-16 was meant to be read.
        if bucket.complete { json["complete"] = true }
        return json
    }

    /// The series that were bucketed and the window each used. Raw ones are absent.
    static func resolutionsJSON(_ used: [String: SeriesResolution]) -> [String: String] {
        used.filter { $0.value != .raw }.mapValues(\.payloadName)
    }

    /// A decimal PayloadJSON passes through as it is: rounded half up to `decimals`, or without
    /// them the shortest digits that read back as the same Double, the digits Android writes,
    /// without its ".0" and exponent. A Double itself would go out with 17 digits,
    /// 72.333333333333329 for 217 / 3. A value no decimal holds stays a Double, which
    /// PayloadJSON leaves out with its key.
    static func number(_ value: Double, decimals: Int? = nil) -> NSNumber {
        guard value.isFinite else { return NSNumber(value: 0) }
        guard let decimal = PayloadJSON.decimal(value, decimals: decimals), !decimal.isNaN else { return NSNumber(value: value) }
        return NSDecimalNumber(decimal: decimal)
    }
}

/// What applying the resolutions to one payload gave.
struct ResolvedSeries {
    /// The payload with every bucketed series replaced and `_resolutions` added.
    var payload: [String: Any]
    /// The samples of windows still open, per type, for the next sync or the next pass.
    var carriedOut: [HealthDataType: [CarriedSample]]
    /// Raw records taken out of the payload, so the caller can tell a payload with nothing
    /// left to send from a full one.
    var absorbedRecords = 0
    /// Buckets put into the payload.
    var bucketCount = 0
    /// Held samples of a type set back to raw, put back into the payload as records.
    var restoredRecords = 0
    /// The resolution used per payload key, as `_resolutions` names it.
    var used: [String: SeriesResolution] = [:]

    /// True when the resolutions took every one of a payload's `totalRecords` out and put
    /// nothing in: there is nothing to post, as on Android. False when nothing was bucketed.
    func leavesNothingToSend(of totalRecords: Int) -> Bool {
        absorbedRecords > 0 && totalRecords - absorbedRecords + bucketCount + restoredRecords <= 0
    }
}

/// Applies the configured resolutions to one payload, as Android's ResolutionApplier does.
///
/// A window still filling is not sent: its samples are carried and bucketed together with the
/// next sync's, so the window goes out once, whole. Every type with a resolution is looked at,
/// also one with no new records, so a carried window goes out once it has closed. A type set
/// back to raw sends what it held as records, where Android drops it.
///
/// A window can go out twice: a Watch syncs to the iPhone hours later, or a source deletes
/// samples and saves them again. Built from only the samples that arrived, the second bucket of
/// steps, distance or calories would make a receiver that adds it to the stored window count a
/// re-saved sample twice, so a closed window of an accumulated series goes out built from
/// `whole` where that holds it, marked complete, for the receiver to replace (P2-16). A window
/// `whole` does not hold goes out as before, unmarked, for the receiver to combine, and so does
/// every window of a measured series, where combining a sample that came again leaves the
/// average, minimum and maximum alone; docs/webhook.md says how.
enum ResolutionApplier {
    /// - Parameters:
    ///   - boundaries: per type, the moment up to which windows count as complete when that is
    ///     earlier than `now`: a read that stopped at the cap or a catch-up cursor continues
    ///     from there, and may still add to the window that contains it.
    ///   - emit: false for a pass that only collects; the raw records still leave the payload
    ///     and every sample is carried.
    ///   - whole: per type, everything HealthKit holds over a range, to build closed windows
    ///     inside it whole from (see `HealthKitManager.readWhole`).
    ///   - completeTypes: accumulated types whose closed windows are complete as built, because
    ///     the caller read every sample of them: a backfill reads a bucketed type from bucket
    ///     bound to bucket bound, in time order.
    static func apply(
        to payload: [String: Any],
        resolutions: [HealthDataType: SeriesResolution],
        carriedIn: [HealthDataType: [CarriedSample]] = [:],
        now: Date,
        boundaries: [HealthDataType: Date] = [:],
        emit: Bool = true,
        whole: [HealthDataType: WholeContent] = [:],
        completeTypes: Set<HealthDataType> = []
    ) -> ResolvedSeries {
        var result = ResolvedSeries(payload: payload, carriedOut: carriedIn)
        for type in ResolutionFamily.configurableTypes {
            guard let family = ResolutionFamily.of(type), let fields = type.seriesFields else { continue }
            let resolution = resolutions[type] ?? SeriesResolution.defaultResolution
            let key = type.countedPayloadKey
            guard resolution != .raw else {
                if let held = result.carriedOut.removeValue(forKey: type), !held.isEmpty {
                    let records = result.payload[key] as? [[String: Any]] ?? []
                    let known = Set(records.compactMap { $0["uuid"] as? String })
                    let restored = held.filter { $0.uuid.map { !known.contains($0) } ?? true }.map { record(from: $0, type: type, fields: fields) }
                    result.payload[key] = restored + records
                    result.restoredRecords += restored.count
                }
                continue
            }
            let records = result.payload.removeValue(forKey: key) as? [[String: Any]] ?? []
            result.absorbedRecords += records.count
            let all = merged(carriedIn[type] ?? [], records.compactMap { sample(from: $0, fields: fields) })

            guard emit else {
                result.carriedOut[type] = all.isEmpty ? nil : all
                continue
            }
            guard !all.isEmpty else {
                result.carriedOut.removeValue(forKey: type)
                continue
            }
            let boundary = min(now, boundaries[type] ?? now)
            let split = SeriesBucketing.splitClosed(SeriesBucketing.bucket(all, resolution: resolution), boundary: boundary)
            if let openFrom = split.openFrom {
                result.carriedOut[type] = all.filter { $0.time >= openFrom }
            } else {
                result.carriedOut.removeValue(forKey: type)
            }
            // An empty array still goes in while everything is held: the receiver asked not to
            // get this series as records, so the payload must not fall back to them.
            let decimals = PayloadJSON.decimals(for: fields.value)
            let closed = split.closed.compactMap { bucket -> Bucket? in
                guard family == .accumulated else { return bucket }
                if completeTypes.contains(type) {
                    var marked = bucket
                    marked.complete = true
                    return marked
                }
                return wholeOrAsIs(bucket, content: whole[type], resolution: resolution)
            }
            result.payload[key] = closed.map { ResolutionPayload.bucketJSON($0, family: family, decimals: decimals) }
            result.used[key] = resolution
            result.bucketCount += closed.count
        }
        if !result.used.isEmpty {
            result.payload[ResolutionPayload.resolutionsKey] = ResolutionPayload.resolutionsJSON(result.used)
        }
        return result
    }

    /// `bucket` rebuilt from everything `content` holds in its window, marked complete; `bucket`
    /// itself, unmarked, when `content` does not hold the window whole. Nil when the window
    /// turns out to hold nothing any more: the samples held for it were deleted, and a window
    /// never sent before has nothing to replace.
    private static func wholeOrAsIs(_ bucket: Bucket, content: WholeContent?, resolution: SeriesResolution) -> Bucket? {
        guard let content, content.covers(bucket.start, bucket.end) else { return bucket }
        let inWindow = content.samples.filter { $0.time >= bucket.start && $0.time < bucket.end }
        guard var rebuilt = SeriesBucketing.bucket(inWindow, resolution: resolution).first else { return nil }
        rebuilt.complete = true
        return rebuilt
    }

    /// Per bucketed accumulated type, from the start of the first window in `payload` to the
    /// end of the last: what a sync has to read whole before it sends them (see `apply`'s
    /// `whole`). Measured series are not sent whole.
    static func windowSpans(in payload: [String: Any]) -> [HealthDataType: DateInterval] {
        var spans: [HealthDataType: DateInterval] = [:]
        for type in ResolutionFamily.configurableTypes where ResolutionFamily.of(type) == .accumulated {
            let buckets = (payload[type.countedPayloadKey] as? [[String: Any]] ?? []).filter { $0["bucket_start"] != nil }
            let starts = buckets.compactMap { ($0["bucket_start"] as? String).flatMap(parseDate) }
            let ends = buckets.compactMap { ($0["bucket_end"] as? String).flatMap(parseDate) }
            if let start = starts.min(), let end = ends.max(), start < end { spans[type] = DateInterval(start: start, end: end) }
        }
        return spans
    }

    /// The newest measurement up to `now` among `carried` and the records of `type` in
    /// `payload`, the boundary of a read that stopped at the cap: the next read continues from
    /// there. A sample dated in the future says nothing about where that is.
    static func newestMeasurement(of type: HealthDataType, in payload: [String: Any], carried: [CarriedSample] = [], notAfter now: Date) -> Date? {
        guard let fields = type.seriesFields else { return nil }
        let records = payload[type.countedPayloadKey] as? [[String: Any]] ?? []
        return (carried + records.compactMap { sample(from: $0, fields: fields) }).map(\.time).filter { $0 <= now }.max()
    }

    /// Held samples first, then the new ones; a uuid seen before is counted once.
    private static func merged(_ held: [CarriedSample], _ new: [CarriedSample]) -> [CarriedSample] {
        var seen = Set<String>()
        return (held + new).filter { sample in
            guard let uuid = sample.uuid else { return true }
            return seen.insert(uuid).inserted
        }
    }

    static func sample(from record: [String: Any], fields: (time: String, value: String)) -> CarriedSample? {
        guard let text = record[fields.time] as? String, let time = parseDate(text),
              let value = (record[fields.value] as? NSNumber)?.doubleValue else { return nil }
        return CarriedSample(
            time: time, value: value, source: record["source"] as? String, uuid: record["uuid"] as? String,
            end: (record["end_time"] as? String).flatMap(parseDate)
        )
    }

    /// A held sample as the record it was read from, for a type set back to raw.
    static func record(from sample: CarriedSample, type: HealthDataType, fields: (time: String, value: String)) -> [String: Any] {
        var record: [String: Any] = [fields.time: sample.time.iso8601String]
        // Heart rate and steps are whole numbers in the schema.
        record[fields.value] = type == .heartRate || type == .steps ? Int(sample.value.rounded()) : sample.value
        if fields.time == "start_time" { record["end_time"] = (sample.end ?? sample.time).iso8601String }
        if let uuid = sample.uuid { record["uuid"] = uuid }
        if let source = sample.source { record["source"] = source }
        return record
    }

    nonisolated(unsafe) private static let plainParser = ISO8601DateFormatter()
    nonisolated(unsafe) private static let fractionalParser: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// The record's own timestamp, with or without fractional seconds.
    private static func parseDate(_ text: String) -> Date? {
        plainParser.date(from: text) ?? fractionalParser.date(from: text)
    }
}

// MARK: - Carry

/// The samples of bucketed windows that were still open at the end of the last sync. Saved
/// only together with the anchors that read them (AnchorCommit), never before: an interrupted
/// sync then leaves both as they were, and the next one reads those samples once, not once
/// from here and once more from HealthKit (Android's fix a64690f).
///
/// Health data, so it lives in a protected file in Application Support, out of the backups,
/// like the retry queue, and not in UserDefaults.
final class BucketCarryStore: @unchecked Sendable {
    static let shared = BucketCarryStore()

    private let directory: URL
    private let lock = NSLock()
    private var fileURL: URL { directory.appendingPathComponent("carry.json") }

    private convenience init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.init(directory: appSupport.appendingPathComponent("bucket_carry", isDirectory: true))
    }

    init(directory: URL) {
        self.directory = directory
    }

    /// What is held, per type. Anything unreadable counts as nothing held.
    func load() -> [HealthDataType: [CarriedSample]] {
        lock.withLock {
            guard let data = try? Data(contentsOf: fileURL),
                  let stored = try? JSONDecoder().decode([String: [CarriedSample]].self, from: data) else { return [:] }
            var carry: [HealthDataType: [CarriedSample]] = [:]
            for (name, samples) in stored {
                if let type = HealthDataType(rawValue: name), !samples.isEmpty { carry[type] = samples }
            }
            return carry
        }
    }

    /// False when the carry could not be written; the caller then keeps its anchors where they
    /// were, so the next sync reads those samples again instead of losing them.
    @discardableResult
    func save(_ carry: [HealthDataType: [CarriedSample]]) -> Bool {
        lock.withLock {
            let stored = Dictionary(uniqueKeysWithValues: carry.filter { !$0.value.isEmpty }.map { ($0.key.rawValue, $0.value) })
            guard !stored.isEmpty else {
                try? FileManager.default.removeItem(at: fileURL)
                return !FileManager.default.fileExists(atPath: fileURL.path)
            }
            guard let data = try? JSONEncoder().encode(stored) else { return false }
            if !FileManager.default.fileExists(atPath: directory.path) {
                try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }
            BackupExclusion.exclude(directory)
            return (try? data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])) != nil
        }
    }
}
