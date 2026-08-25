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
}
