import CryptoKit
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

            var session: [String: Any] = [
                "session_end_time": sessionEnd.iso8601String,
                "duration_seconds": Int(sessionEnd.timeIntervalSince(sessionStart)),
                "stages": stages
            ]
            if let uuid = sessionUuid(for: group) { session["uuid"] = uuid }
            if let source = sessionSource(for: group) { session["source"] = source }
            return session
        }
    }

    /// The app or device that recorded most of the night, as Android's session names the app
    /// that wrote it. In bed only counts when there are no sleep stages: an iPhone writes in bed
    /// for the whole night while the Watch writes the stages.
    static func sessionSource(for group: [SleepStageSample]) -> String? {
        let asleep = group.filter { $0.stage != "in_bed" }
        var time: [String: TimeInterval] = [:]
        for sample in asleep.isEmpty ? group : asleep {
            guard let source = sample.source else { continue }
            time[source, default: 0] += sample.end.timeIntervalSince(sample.start)
        }
        return time.max { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }?.key
    }

    /// A stable id for a night, so a receiver can replace a session it already has when the
    /// night comes back longer (read before it ended, or cut by the sample limit) instead of
    /// counting both. Home Assistant keys a session without one by its end and duration, and
    /// those change as the night grows.
    ///
    /// Derived from the earliest stage, which stays the same while a night grows at the end,
    /// and hashed so it never equals the uuid of one of its own stages. None when that stage
    /// has no uuid. A night clipped at its start by the read window still gets a new id; that
    /// needs a read that starts early enough to see whole nights.
    static func sessionUuid(for group: [SleepStageSample]) -> String? {
        let earliest = group.min { lhs, rhs in
            lhs.start != rhs.start ? lhs.start < rhs.start : (lhs.uuid ?? "") < (rhs.uuid ?? "")
        }
        guard let stageUuid = earliest?.uuid else { return nil }
        return derivedUuid("sleep-session:\(stageUuid)")
    }

    /// A uuid derived from `name`, for a record HealthKit has no uuid for. Shaped as an RFC 4122
    /// name-based UUID (version 5 bits), uppercase like HealthKit's.
    static func derivedUuid(_ name: String) -> String {
        var bytes = Array(SHA256.hash(data: Data(name.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        let uuid = UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
        return uuid.uuidString
    }
}
