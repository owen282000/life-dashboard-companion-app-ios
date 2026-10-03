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
/// filling can wait for the next sync. The uuid is kept, unlike on Android, because a HealthKit
/// catch-up read can return a sample the carry already holds, and it must count once.
struct CarriedSample: Codable, Equatable, Sendable {
    let time: Date
    let value: Double
    var source: String?
    var uuid: String?
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

    static func bucketJSON(_ bucket: Bucket, family: ResolutionFamily) -> [String: Any] {
        var json: [String: Any] = [
            "bucket_start": bucket.start.iso8601String,
            "bucket_end": bucket.end.iso8601String,
            "sample_count": bucket.sampleCount
        ]
        switch family {
        case .accumulated:
            json["total"] = number(bucket.total)
        case .sampled:
            json["avg"] = number(bucket.mean)
            json["min"] = number(bucket.minimum)
            json["max"] = number(bucket.maximum)
        }
        if !bucket.sources.isEmpty { json["sources"] = bucket.sources }
        return json
    }

    /// The series that were bucketed and the window each used. Raw ones are absent.
    static func resolutionsJSON(_ used: [String: SeriesResolution]) -> [String: String] {
        used.filter { $0.value != .raw }.mapValues(\.payloadName)
    }

    /// The shortest text that reads back as the same Double, as Android writes it: a Double
    /// itself goes through JSONSerialization with 17 digits, 72.333333333333329 for 217 / 3.
    static func number(_ value: Double) -> NSNumber {
        guard value.isFinite else { return NSNumber(value: 0) }
        return NSDecimalNumber(string: "\(value)", locale: Locale(identifier: "en_US_POSIX"))
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
    /// The resolution used per payload key, as `_resolutions` names it.
    var used: [String: SeriesResolution] = [:]

    /// True when every one of a payload's `totalRecords` went into a window still filling and
    /// no window closed: there is nothing to post, as on Android.
    func leavesNothingToSend(of totalRecords: Int) -> Bool {
        totalRecords - absorbedRecords + bucketCount <= 0
    }
}

/// Applies the configured resolutions to one payload, as Android's ResolutionApplier does.
///
/// A window still filling is not sent: its samples are carried and bucketed together with the
/// next sync's, so the window goes out once, whole. Every type with a resolution is looked at,
/// also one with no new records, so a carried window goes out once it has closed. A type set
/// back to raw lets go of what it held: its records are sent as they are.
///
/// The one case that sends a window twice is a record arriving late for a window already sent,
/// a Watch that syncs to the iPhone hours later. Buckets carry what a receiver needs to merge
/// that exactly, and docs/webhook.md says how.
enum ResolutionApplier {
    /// - Parameters:
    ///   - boundaries: per type, the moment up to which windows count as complete when that is
    ///     earlier than `now`: a read that stopped at the cap or a catch-up cursor continues
    ///     from there, and may still add to the window that contains it.
    ///   - emit: false for a pass that only collects; the raw records still leave the payload
    ///     and every sample is carried.
    static func apply(
        to payload: [String: Any],
        resolutions: [HealthDataType: SeriesResolution],
        carriedIn: [HealthDataType: [CarriedSample]] = [:],
        now: Date,
        boundaries: [HealthDataType: Date] = [:],
        emit: Bool = true
    ) -> ResolvedSeries {
        var result = ResolvedSeries(payload: payload, carriedOut: carriedIn)
        for type in ResolutionFamily.configurableTypes {
            guard let family = ResolutionFamily.of(type), let fields = type.seriesFields else { continue }
            let resolution = resolutions[type] ?? SeriesResolution.defaultResolution
            guard resolution != .raw else {
                result.carriedOut.removeValue(forKey: type)
                continue
            }
            let key = type.countedPayloadKey
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
            result.payload[key] = split.closed.map { ResolutionPayload.bucketJSON($0, family: family) }
            result.used[key] = resolution
            result.bucketCount += split.closed.count
        }
        if !result.used.isEmpty {
            result.payload[ResolutionPayload.resolutionsKey] = ResolutionPayload.resolutionsJSON(result.used)
        }
        return result
    }

    /// The newest measurement among `carried` and the records of `type` in `payload`, the
    /// boundary of a read that stopped at the cap: the next read continues from there.
    static func newestMeasurement(of type: HealthDataType, in payload: [String: Any], carried: [CarriedSample] = []) -> Date? {
        guard let fields = type.seriesFields else { return nil }
        let records = payload[type.countedPayloadKey] as? [[String: Any]] ?? []
        return (carried + records.compactMap { sample(from: $0, fields: fields) }).map(\.time).max()
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
        return CarriedSample(time: time, value: value, source: record["source"] as? String, uuid: record["uuid"] as? String)
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

    func save(_ carry: [HealthDataType: [CarriedSample]]) {
        lock.withLock {
            let stored = Dictionary(uniqueKeysWithValues: carry.filter { !$0.value.isEmpty }.map { ($0.key.rawValue, $0.value) })
            guard !stored.isEmpty else {
                try? FileManager.default.removeItem(at: fileURL)
                return
            }
            guard let data = try? JSONEncoder().encode(stored) else { return }
            if !FileManager.default.fileExists(atPath: directory.path) {
                try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }
            BackupExclusion.exclude(directory)
            try? data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
    }
}
