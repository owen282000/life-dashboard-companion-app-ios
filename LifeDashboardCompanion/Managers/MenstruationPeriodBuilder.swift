import Foundation

/// A single menstrual flow sample, decoupled from HealthKit so period derivation is unit-testable.
struct FlowSample {
    let start: Date
    let end: Date
    var uuid: String?
    var source: String?
}

enum MenstruationPeriodBuilder {
    /// Flow days separated by more than this gap belong to different periods.
    /// 48 hours tolerates a single missed logging day within one period.
    static let maxGap: TimeInterval = 48 * 3600

    /// How far before a read the flow days are read too, so a period is built from its first
    /// day. A period longer than this gets a new uuid for the part a sync sees.
    static let lookback: TimeInterval = 14 * 86_400

    /// Derives menstruation periods from individual flow samples, matching the Android
    /// companion app's `menstruation_period` records (HealthKit has no period type of its own).
    /// With `reaching`, only the periods with a flow day from that moment on.
    static func periods(from samples: [FlowSample], reaching readStart: Date? = nil) -> [[String: Any]] {
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

        if let readStart {
            groups = groups.filter { group in group.contains { $0.start >= readStart } }
        }

        return groups.map { group in
            let start = group.map(\.start).min() ?? Date.distantPast
            let end = group.map(\.end).max() ?? Date.distantPast
            var period: [String: Any] = [
                "start_time": start.iso8601String,
                "end_time": end.iso8601String
            ]
            // Like a sleep session's: from the first flow day, which stays the same while the
            // period grows at the end, so a receiver replaces the period instead of adding one.
            let first = group.min { lhs, rhs in
                lhs.start != rhs.start ? lhs.start < rhs.start : (lhs.uuid ?? "") < (rhs.uuid ?? "")
            }
            if let uuid = first?.uuid { period["uuid"] = SleepSessionBuilder.derivedUuid("menstruation-period:\(uuid)") }
            if let source = first?.source { period["source"] = source }
            return period
        }
    }
}
