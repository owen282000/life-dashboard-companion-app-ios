import Foundation

/// Sync status shared with the home screen widget via the app group container.
/// Compiled into both the app and the widget extension.
enum SharedSyncStatus {
    static let appGroupId = "group.com.owen282000.lifedashboard"

    struct Status {
        let lastSync: Date?
        let lastSuccess: Bool
        let recordsToday: Int
    }

    static func record(success: Bool, records: Int) {
        guard let defaults = UserDefaults(suiteName: appGroupId) else { return }

        var todayCount = defaults.integer(forKey: "records_today")
        if let lastDate = defaults.object(forKey: "records_today_date") as? Date,
           !Calendar.current.isDateInToday(lastDate) {
            todayCount = 0
        }
        if success {
            todayCount += records
        }

        defaults.set(todayCount, forKey: "records_today")
        defaults.set(Date(), forKey: "records_today_date")
        defaults.set(Date(), forKey: "last_sync")
        defaults.set(success, forKey: "last_sync_success")
    }

    static func read() -> Status {
        guard let defaults = UserDefaults(suiteName: appGroupId) else {
            return Status(lastSync: nil, lastSuccess: true, recordsToday: 0)
        }

        var records = defaults.integer(forKey: "records_today")
        if let lastDate = defaults.object(forKey: "records_today_date") as? Date,
           !Calendar.current.isDateInToday(lastDate) {
            records = 0
        }

        return Status(
            lastSync: defaults.object(forKey: "last_sync") as? Date,
            lastSuccess: defaults.object(forKey: "last_sync_success") as? Bool ?? true,
            recordsToday: records
        )
    }
}
