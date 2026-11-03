import Foundation

/// The line on Home while automatic syncs wait: why they do, or when and where they go. It never
/// names a next sync time, since iOS picks that moment.
enum ScheduleStatusLine {
    /// No destination first (then "Sync Now still works" would not be true), then why automatic
    /// syncs are held, then the schedule itself, with where it goes: webhooks, MQTT or both.
    nonisolated static func text(schedule: SyncSchedule, webhookCount: Int, mqtt: Bool, now: Date, timeZone: TimeZone) -> String {
        let cadence = schedule.summary
        guard webhookCount > 0 || mqtt else {
            return String(localized: "\(cadence), no destination yet")
        }
        switch schedule.hold(at: now, timeZone: timeZone) {
        case .never:
            return String(localized: "Automatic syncs are off. Sync Now still works.")
        case .quiet(let until):
            return String(localized: "Quiet hours until \(until.formatted). Sync Now still works.")
        case .dayOff:
            return String(localized: "No automatic syncs today. Sync Now still works.")
        case nil:
            if webhookCount == 0 { return String(localized: "\(cadence) to MQTT") }
            if mqtt { return String(localized: "\(cadence) to \(webhookCount) webhooks and MQTT") }
            return String(localized: "\(cadence) to \(webhookCount) webhooks")
        }
    }
}

// MARK: - Display helpers

extension SyncSchedule {
    /// "Every 60 min · Mon Tue Wed · quiet 23:00 to 07:00", or "After 08:00, 21:00 · ..." for
    /// fixed times: "after", because iOS runs a time at its first chance, not on the minute.
    var summary: String {
        var parts: [String] = []
        switch mode {
        case .interval:
            parts.append(String(localized: "Every \(intervalMinutes) min"))
        case .times:
            let sorted = Array(Set(times)).sorted()
            parts.append(sorted.isEmpty
                ? String(localized: "No sync times yet")
                : String(localized: "After \(sorted.map(\.formatted).joined(separator: ", "))"))
        }
        if days.count < Weekday.allCases.count {
            parts.append(Weekday.allCases.filter(days.contains).map(\.shortName).joined(separator: " "))
        }
        if let quiet = quietWindow, quiet.from != quiet.to {
            parts.append(String(localized: "quiet \(quiet.from.formatted) to \(quiet.to.formatted)"))
        }
        return parts.joined(separator: " · ")
    }
}

extension Weekday {
    /// Calendar's symbols start on Sunday; Weekday starts on Monday.
    private var symbolIndex: Int { ((Weekday.allCases.firstIndex(of: self) ?? 0) + 1) % 7 }

    var shortName: String { Calendar.current.shortStandaloneWeekdaySymbols[symbolIndex] }

    var fullName: String { Calendar.current.standaloneWeekdaySymbols[symbolIndex] }
}

extension TimeOfDay {
    init(date: Date, calendar: Calendar = .current) {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        self.init(hour: parts.hour ?? 0, minute: parts.minute ?? 0)
    }

    /// This time on a fixed day without clock changes, for pickers and formatting only; today
    /// would turn 02:30 into 03:30 on the night summer time starts.
    var referenceDate: Date {
        Calendar.current.date(from: DateComponents(year: 2001, month: 1, day: 1, hour: hour, minute: minute)) ?? Date()
    }

    /// "23:00" or "11:00 PM", as the user's locale writes it.
    var formatted: String { referenceDate.formatted(date: .omitted, time: .shortened) }
}
