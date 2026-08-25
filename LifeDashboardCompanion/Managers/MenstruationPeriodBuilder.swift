import Foundation

/// A single menstrual flow sample, decoupled from HealthKit so period derivation is unit-testable.
struct FlowSample {
    let start: Date
    let end: Date
}

enum MenstruationPeriodBuilder {
    /// Flow days separated by more than this gap belong to different periods.
    /// 48 hours tolerates a single missed logging day within one period.
    static let maxGap: TimeInterval = 48 * 3600

    /// Derives menstruation periods from individual flow samples, matching the Android
    /// companion app's `menstruation_period` records (HealthKit has no period type of its own).
    static func periods(from samples: [FlowSample]) -> [[String: Any]] {
        let sorted = samples.sorted { $0.start < $1.start }

        var groups: [[FlowSample]] = []
        var current: [FlowSample] = []

        for sample in sorted {
            if let last = current.last, sample.start.timeIntervalSince(last.end) > maxGap {
                groups.append(current)
                current = [sample]
            } else {
                current.append(sample)
            }
        }
        if !current.isEmpty {
            groups.append(current)
        }

        return groups.map { group in
            let start = group.map(\.start).min() ?? Date.distantPast
            let end = group.map(\.end).max() ?? Date.distantPast
            return [
                "start_time": start.iso8601String,
                "end_time": end.iso8601String
            ]
        }
    }
}
