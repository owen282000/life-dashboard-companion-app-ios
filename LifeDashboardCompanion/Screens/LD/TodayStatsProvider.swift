import HealthKit
import SwiftUI

/// The figures TodayPanel may show. Nothing sensitive is in this list, so nothing sensitive can
/// reach the panel.
enum TodayStatKind: CaseIterable, Sendable {
    case steps, sleep, restingHeartRate, weight

    var dataType: HealthDataType {
        switch self {
        case .steps: return .steps
        case .sleep: return .sleep
        case .restingHeartRate: return .restingHeartRate
        case .weight: return .weight
        }
    }

    /// In the Health app's habit: pounds where the phone uses US measures, kilograms elsewhere.
    static var weighsInPounds: Bool { Locale.current.measurementSystem == .us }
}

struct TodayStat: Identifiable, Equatable, Sendable {
    let kind: TodayStatKind
    /// Oldest first, only the days with a value. Steps in steps, sleep in minutes, resting heart
    /// rate in beats per minute, weight in the unit of `weighsInPounds`.
    let series: [Double]

    var id: TodayStatKind { kind }
    var latest: Double { series.last ?? 0 }
}

/// The figures of TodayPanel: read-only, off the main thread, for the enabled types only. It asks
/// for no access: a type iOS will not read for us simply has no figures, and drops off the panel.
@MainActor
final class TodayStatsProvider: ObservableObject {
    @Published private(set) var stats: [TodayStat] = []
    @Published private(set) var recordsToday = 0
    /// False until the first read is back, so the panel does not flash its fallback first.
    @Published private(set) var hasLoaded = false

    private var latestRefresh = 0

    func refresh(enabled: Set<HealthDataType>) async {
        latestRefresh += 1
        let refresh = latestRefresh
        let kinds = TodayStatKind.allCases.filter { enabled.contains($0.dataType) }
        let reads = await Task.detached(priority: .utility) { await TodayHealthReader.read(kinds) }.value
        guard refresh == latestRefresh else { return }

        let previous = stats
        stats = kinds.compactMap { kind in
            switch reads[kind] {
            case .series(let series):
                return series.isEmpty ? nil : TodayStat(kind: kind, series: series)
            case .locked, nil:
                // Health data cannot be read while the phone is locked: what we had stays.
                return previous.first { $0.kind == kind }
            }
        }
        recordsToday = SharedSyncStatus.read().recordsToday
        hasLoaded = true
    }
}

private enum TodayHealthReader {
    enum Read: Sendable {
        case series([Double])
        case locked
    }

    private static let days = 7

    static func read(_ kinds: [TodayStatKind]) async -> [TodayStatKind: Read] {
        await withTaskGroup(of: (TodayStatKind, Read).self) { group in
            for kind in kinds {
                group.addTask { (kind, await read(kind)) }
            }
            var reads: [TodayStatKind: Read] = [:]
            for await (kind, read) in group {
                reads[kind] = read
            }
            return reads
        }
    }

    private static func read(_ kind: TodayStatKind) async -> Read {
        #if DEBUG
        // For screenshots: the simulator has no Health data, so -ld.demoSteps "5200,7100,...",
        // -ld.demoSleep (minutes), -ld.demoRest and -ld.demoWeight stand in for the last seven days.
        if let demo = UserDefaults.standard.string(forKey: demoKey(kind)) {
            return .series(demo.split(separator: ",").compactMap { Double($0) })
        }
        #endif
        do {
            switch kind {
            case .steps:
                let days = try await daily(.stepCount, options: .cumulativeSum) {
                    $0.sumQuantity()?.doubleValue(for: .count())
                }
                // A day without a sample is a day without steps, unless the whole week is empty.
                return .series(days.allSatisfy { $0 == nil } ? [] : days.map { $0 ?? 0 })
            case .sleep:
                return .series(try await minutesAsleepPerNight())
            case .restingHeartRate:
                let days = try await daily(.restingHeartRate, options: .discreteAverage) {
                    $0.averageQuantity()?.doubleValue(for: HKUnit.count().unitDivided(by: .minute()))
                }
                return .series(days.compactMap { $0 })
            case .weight:
                let days = try await daily(.bodyMass, options: .mostRecent) {
                    $0.mostRecentQuantity()?.doubleValue(for: TodayStatKind.weighsInPounds ? .pound() : .gramUnit(with: .kilo))
                }
                return .series(days.compactMap { $0 })
            }
        } catch let error as HKError where error.code == .errorDatabaseInaccessible {
            return .locked
        } catch {
            return .series([])
        }
    }

    #if DEBUG
    private static func demoKey(_ kind: TodayStatKind) -> String {
        switch kind {
        case .steps: return "ld.demoSteps"
        case .sleep: return "ld.demoSleep"
        case .restingHeartRate: return "ld.demoRest"
        case .weight: return "ld.demoWeight"
        }
    }
    #endif

    /// One value per day of the last week, oldest first, nil for a day without samples. The
    /// statistics query merges overlapping iPhone and Watch samples, as the Health app does.
    private static func daily(
        _ identifier: HKQuantityTypeIdentifier,
        options: HKStatisticsOptions,
        value: (HKStatistics) -> Double?
    ) async throws -> [Double?] {
        let calendar = Calendar.current
        let end = Date()
        let today = calendar.startOfDay(for: end)
        guard let start = calendar.date(byAdding: .day, value: -(days - 1), to: today) else { return [] }
        let query = HKStatisticsCollectionQueryDescriptor(
            predicate: .quantitySample(
                type: HKQuantityType(identifier),
                predicate: HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
            ),
            options: options,
            anchorDate: today,
            intervalComponents: DateComponents(day: 1)
        )
        let collection = try await query.result(for: HealthKitManager.shared.healthStore)
        return (0..<days).map { offset in
            calendar.date(byAdding: .day, value: offset, to: start)
                .flatMap { collection.statistics(for: $0) }
                .flatMap(value)
        }
    }

    /// A night runs from 18:00 the evening before to 18:00 on its day, so it counts as one night
    /// past midnight and an afternoon nap still lands on the day it was taken.
    private static func minutesAsleepPerNight() async throws -> [Double] {
        let calendar = Calendar.current
        let now = Date()
        let today = calendar.startOfDay(for: now)
        let nights: [DateInterval] = (0..<days).reversed().compactMap { back in
            guard let day = calendar.date(byAdding: .day, value: -back, to: today),
                  let start = calendar.date(byAdding: .hour, value: -6, to: day),
                  let end = calendar.date(byAdding: .hour, value: 18, to: day) else { return nil }
            return DateInterval(start: start, end: end)
        }
        guard let first = nights.first?.start else { return [] }
        let query = HKSampleQueryDescriptor(
            predicates: [.categorySample(
                type: HKCategoryType(.sleepAnalysis),
                predicate: HKQuery.predicateForSamples(withStart: first, end: now)
            )],
            sortDescriptors: []
        )
        let asleep = try await query.result(for: HealthKitManager.shared.healthStore)
            .filter { sample in
                HKCategoryValueSleepAnalysis(rawValue: sample.value).map(HKCategoryValueSleepAnalysis.allAsleepValues.contains) ?? false
            }
            .map { DateInterval(start: $0.startDate, end: $0.endDate) }
            .sorted()
        return nights.map { minutes(of: asleep, in: $0) }.filter { $0 > 0 }
    }

    /// Time covered inside `window` by intervals sorted by start. An iPhone and a Watch both log
    /// the same night, so what overlaps counts once.
    private static func minutes(of intervals: [DateInterval], in window: DateInterval) -> Double {
        var seconds = 0.0
        var reached = window.start
        for interval in intervals {
            let from = max(interval.start, reached)
            let to = min(interval.end, window.end)
            if to > from {
                seconds += to.timeIntervalSince(from)
                reached = to
            }
        }
        return seconds / 60
    }
}
