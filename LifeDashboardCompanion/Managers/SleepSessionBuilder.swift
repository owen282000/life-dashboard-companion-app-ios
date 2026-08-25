import Foundation

/// A single sleep stage sample, decoupled from HealthKit so session grouping is unit-testable.
struct SleepStageSample {
    let stage: String
    let start: Date
    let end: Date
    var uuid: String?
    var source: String?
}

enum SleepSessionBuilder {
    /// Samples separated by more than this gap belong to different sessions.
    static let sessionGap: TimeInterval = 3600

    /// Groups stage samples into sessions and maps them to webhook payload dictionaries.
    static func sessions(from samples: [SleepStageSample]) -> [[String: Any]] {
        let sorted = samples.sorted { $0.start < $1.start }

        var groups: [[SleepStageSample]] = []
        var current: [SleepStageSample] = []

        for sample in sorted {
            if let last = current.last, sample.start.timeIntervalSince(last.end) > sessionGap {
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
            let sessionStart = group.map(\.start).min() ?? Date.distantPast
            let sessionEnd = group.map(\.end).max() ?? Date.distantPast

            let stages: [[String: Any]] = group.map { sample in
                var stage: [String: Any] = [
                    "stage": sample.stage,
                    "start_time": sample.start.iso8601String,
                    "end_time": sample.end.iso8601String,
                    "duration_seconds": Int(sample.end.timeIntervalSince(sample.start))
                ]
                if let uuid = sample.uuid { stage["uuid"] = uuid }
                if let source = sample.source { stage["source"] = source }
                return stage
            }

            return [
                "session_end_time": sessionEnd.iso8601String,
                "duration_seconds": Int(sessionEnd.timeIntervalSince(sessionStart)),
                "stages": stages
            ]
        }
    }
}
