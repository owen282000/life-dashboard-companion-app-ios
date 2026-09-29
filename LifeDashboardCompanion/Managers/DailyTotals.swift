import Foundation
import HealthKit
import OSLog

/// One field of a `daily_totals` entry: the payload key, the data type that has to be enabled
/// for it, and the unit it is sent in. The HealthKit identifiers it sums are the type's own
/// sample types, so the total always covers what the raw array of that type carries.
struct DailyTotalMetric {
    let field: String
    let type: HealthDataType
    let unit: HKUnit
    var isInteger = false
    /// The field is only sent on days this identifier has a sum.
    var requiredOnDay: HKQuantityTypeIdentifier?

    var identifiers: [HKQuantityTypeIdentifier] {
        type.hkSampleTypes.compactMap { ($0 as? HKQuantityType).map { HKQuantityTypeIdentifier(rawValue: $0.identifier) } }
    }
}

/// Per-day totals with the schema of the Android app's `daily_totals`, computed with HealthKit's
/// statistics queries. Those count overlapping samples from several sources (iPhone and Watch)
/// once, by the source order the user set in the Health app, so the figures match what Health
/// shows. The pure functions here are tested without HealthKit; the query is the extension on
/// HealthKitManager below.
enum DailyTotals {
    static let payloadKey = "daily_totals"

    /// Every sync carries today and the two days before, as the Android app does, so a total
    /// that settles late (a Watch that uploads hours later) is still sent.
    static let syncDays = 2

    /// Same bound as the Android app puts on every Health Connect call.
    static let queryTimeout: TimeInterval = 10

    /// The Android schema closes an entry at these keys (`additionalProperties: false`), so a
    /// new row below is only possible for a key the Android app sends too. A new type's total
    /// is one row.
    ///
    /// Where iOS differs: `distance_meters` sums what the Distance type reads (walking and
    /// running today), where Health Connect's distance covers every activity. HealthKit has no
    /// total energy type, so `total_calories` is resting plus active energy and is only sent on
    /// days with resting energy, which an iPhone without a Watch usually does not record; active
    /// energy alone under the name total would read as a real figure some 1500 kcal too low.
    static let metrics: [DailyTotalMetric] = [
        DailyTotalMetric(field: "steps", type: .steps, unit: .count(), isInteger: true),
        DailyTotalMetric(field: "distance_meters", type: .distance, unit: .meter()),
        DailyTotalMetric(field: "active_calories", type: .activeCalories, unit: .kilocalorie()),
        DailyTotalMetric(field: "total_calories", type: .totalCalories, unit: .kilocalorie(), requiredOnDay: .basalEnergyBurned)
    ]

    static let schemaFields: Set<String> = ["date", "steps", "distance_meters", "active_calories", "total_calories"]

    /// Gregorian in the device's time zone. The user's own calendar can be Buddhist or Japanese,
    /// which would put year 2569 or 8 in the date and stop a receiver's day sensors for good.
    static func calendar(timeZone: TimeZone = .current) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }

    /// From local midnight `days` days before today up to now.
    static func window(days: Int = syncDays, now: Date = Date(), calendar: Calendar) -> DateInterval {
        let today = calendar.startOfDay(for: now)
        let start = calendar.date(byAdding: .day, value: -days, to: today) ?? today
        return DateInterval(start: start, end: max(now, start))
    }

    /// Every whole local day a backfill window touches, capped at now, the way the Android app
    /// asks for a window's totals: a day cut by a window bound is asked for in full by both
    /// windows and arrives twice with the same figures. Nil when nothing is left.
    static func wholeDays(touching interval: DateInterval, now: Date = Date(), calendar: Calendar) -> DateInterval? {
        let start = calendar.startOfDay(for: interval.start)
        guard let dayAfter = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: interval.end)) else {
            return nil
        }
        let end = min(dayAfter, now)
        return start < end ? DateInterval(start: start, end: end) : nil
    }

    /// The `yyyy-MM-dd` of every local day the interval touches, oldest first.
    static func days(in interval: DateInterval, calendar: Calendar) -> [String] {
        var days: [String] = []
        var day = calendar.startOfDay(for: interval.start)
        while day < interval.end {
            days.append(dateString(day, calendar: calendar))
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = calendar.startOfDay(for: next)
        }
        return days
    }

    static func dateString(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04ld-%02ld-%02ld", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// Payload entries from per-identifier sums keyed by day. A nil value for an identifier
    /// means its query failed: the fields that need it are left out for every day, since a
    /// total with a missing half would overwrite a receiver's right figure with a lower one. A
    /// day without samples leaves the field out rather than sending 0, which a receiver would
    /// store as a real day; HealthKit also reports a read it was denied as no samples. Days
    /// without any field are dropped.
    static func entries(
        days: [String],
        sums: [HKQuantityTypeIdentifier: [String: Double]?],
        metrics: [DailyTotalMetric] = metrics
    ) -> [[String: Any]] {
        days.compactMap { day -> [String: Any]? in
            var entry: [String: Any] = [:]
            for metric in metrics {
                if let value = value(of: metric, on: day, sums: sums) {
                    entry[metric.field] = value
                }
            }
            guard !entry.isEmpty else { return nil }
            entry["date"] = day
            return entry
        }
    }

    /// The copy of a payload that waits in the retry queue. The entry for the day it was built
    /// on is the one still growing, and the queue can be drained after a later sync went out
    /// (on reconnect, at launch, from Retry Now), which would put an older figure back on the
    /// receiver. Earlier days are final apart from late uploads, which the next syncs re-send.
    static func forQueue(_ payload: [String: Any], builtOn day: String) -> [String: Any] {
        guard let entries = payload[payloadKey] as? [[String: Any]] else { return payload }
        var copy = payload
        let kept = entries.filter { $0["date"] as? String != day }
        copy[payloadKey] = kept.isEmpty ? nil : kept
        return copy
    }

    private static func value(
        of metric: DailyTotalMetric,
        on day: String,
        sums: [HKQuantityTypeIdentifier: [String: Double]?]
    ) -> Any? {
        var parts: [Double] = []
        for identifier in metric.identifiers {
            guard let perDay = sums[identifier] ?? nil else { return nil }
            if let part = perDay[day] { parts.append(part) }
        }
        if let required = metric.requiredOnDay, (sums[required] ?? nil)?[day] == nil { return nil }
        guard !parts.isEmpty else { return nil }
        let total = parts.reduce(0, +)
        // JSONSerialization raises on NaN and infinity, which would end the sync.
        guard total.isFinite, total.magnitude < 1e15 else { return nil }
        return metric.isInteger ? Int(total.rounded()) : total
    }
}

private let dailyTotalsLogger = Logger(subsystem: "com.owen282000.lifedashboard", category: "DailyTotals")

extension HealthKitManager {

    /// The totals of every local day the interval touches, for the enabled types. Each HealthKit
    /// identifier is one statistics query, all in parallel and each bounded at
    /// `DailyTotals.queryTimeout`; a query that fails or does not answer leaves its fields out
    /// and never fails the sync.
    func readDailyTotals(
        in interval: DateInterval,
        enabledTypes: Set<HealthDataType>,
        calendar: Calendar = DailyTotals.calendar()
    ) async -> [[String: Any]] {
        let metrics = DailyTotals.metrics.filter { enabledTypes.contains($0.type) }
        var units: [HKQuantityTypeIdentifier: HKUnit] = [:]
        for metric in metrics {
            for identifier in metric.identifiers { units[identifier] = metric.unit }
        }
        guard !units.isEmpty, interval.duration > 0 else { return [] }

        let sums = await withTaskGroup(of: (HKQuantityTypeIdentifier, [String: Double]?).self) { group in
            for (identifier, unit) in units {
                group.addTask {
                    (identifier, await self.dailySums(of: identifier, unit: unit, in: interval, calendar: calendar))
                }
            }
            var sums: [HKQuantityTypeIdentifier: [String: Double]?] = [:]
            for await (identifier, perDay) in group {
                sums.updateValue(perDay, forKey: identifier)
            }
            return sums
        }
        return DailyTotals.entries(days: DailyTotals.days(in: interval, calendar: calendar), sums: sums, metrics: metrics)
    }

    /// Day sums of one identifier keyed by `yyyy-MM-dd`; days without samples are absent. Nil
    /// when the query failed (a locked device among others) or did not answer in time.
    private func dailySums(
        of identifier: HKQuantityTypeIdentifier,
        unit: HKUnit,
        in interval: DateInterval,
        calendar: Calendar
    ) async -> [String: Double]? {
        let once = ResumeOnce()
        let healthStore = self.healthStore
        return await withCheckedContinuation { continuation in
            // No strict start: a sample over the first midnight is split between the days
            // instead of dropped.
            let query = HKStatisticsCollectionQuery(
                quantityType: HKQuantityType(identifier),
                quantitySamplePredicate: HKQuery.predicateForSamples(withStart: interval.start, end: interval.end),
                options: .cumulativeSum,
                anchorDate: calendar.startOfDay(for: interval.start),
                intervalComponents: DateComponents(day: 1)
            )
            query.initialResultsHandler = { _, collection, error in
                guard let collection, error == nil else {
                    dailyTotalsLogger.error("Daily totals for \(identifier.rawValue) failed: \(error?.localizedDescription ?? "no result")")
                    if once.claim() { continuation.resume(returning: nil) }
                    return
                }
                var sums: [String: Double] = [:]
                collection.enumerateStatistics(from: interval.start, to: interval.end) { statistics, _ in
                    if let sum = statistics.sumQuantity() {
                        sums[DailyTotals.dateString(statistics.startDate, calendar: calendar)] = sum.doubleValue(for: unit)
                    }
                }
                if once.claim() { continuation.resume(returning: sums) }
            }
            healthStore.execute(query)

            // A continuation ignores task cancellation, so the bound stops the query itself.
            DispatchQueue.global().asyncAfter(deadline: .now() + DailyTotals.queryTimeout) {
                guard once.claim() else { return }
                healthStore.stop(query)
                dailyTotalsLogger.error("Daily totals for \(identifier.rawValue) did not answer within \(Int(DailyTotals.queryTimeout)) s")
                continuation.resume(returning: nil)
            }
        }
    }
}

/// Lets exactly one of a query's result handler and its timeout resume the continuation.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}
