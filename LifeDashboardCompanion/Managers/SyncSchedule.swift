import Foundation

/// When a background sync may run. A port of the Android app's SyncSchedule: two modes (a fixed
/// interval or a list of times of day), both narrowed by a weekday filter and a quiet window,
/// stored in the same text formats so a settings backup means the same thing on both platforms.
///
/// Free of HealthKit and BackgroundTasks on purpose: `nextRun` is the whole decision and is
/// unit tested with an explicit time zone. BackgroundSyncManager turns it into background task
/// requests and into a yes or no for each HealthKit wakeup.
enum SyncMode: String, CaseIterable, Sendable {
    case interval = "INTERVAL"
    case times = "TIMES"
}

/// A wall-clock time of day, minute precision, written "HH:mm" like java.time's LocalTime.
struct TimeOfDay: Hashable, Comparable, Sendable {
    let hour: Int
    let minute: Int

    /// Out-of-range values are clamped, so a time can never land on the next day.
    init(hour: Int, minute: Int) {
        self.hour = min(max(hour, 0), 23)
        self.minute = min(max(minute, 0), 59)
    }

    /// "07:30" or "07:30:00" to a time, as LocalTime.parse reads them; the seconds are dropped.
    /// Nil for anything else, including out-of-range values.
    init?(_ text: String) {
        let parts = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ":", omittingEmptySubsequences: false)
        guard (2...3).contains(parts.count), parts.allSatisfy({ $0.count == 2 && $0.allSatisfy { $0.isASCII && $0.isNumber } }),
              let hour = Int(parts[0]), let minute = Int(parts[1]),
              (0..<24).contains(hour), (0..<60).contains(minute),
              parts.count == 2 || Int(parts[2]).map({ (0..<60).contains($0) }) == true else { return nil }
        self.init(hour: hour, minute: minute)
    }

    var secondOfDay: Int { (hour * 60 + minute) * 60 }

    var text: String { String(format: "%02d:%02d", hour, minute) }

    static func < (lhs: TimeOfDay, rhs: TimeOfDay) -> Bool { lhs.secondOfDay < rhs.secondOfDay }
}

/// Monday first, as java.time's DayOfWeek; the raw value is the name the settings store.
enum Weekday: String, CaseIterable, Sendable {
    case monday = "MONDAY", tuesday = "TUESDAY", wednesday = "WEDNESDAY", thursday = "THURSDAY"
    case friday = "FRIDAY", saturday = "SATURDAY", sunday = "SUNDAY"

    /// Monday to Friday, the one preset the schedule refers to by name.
    static let workdays: Set<Weekday> = [.monday, .tuesday, .wednesday, .thursday, .friday]
}

struct QuietWindow: Hashable, Sendable {
    let from: TimeOfDay
    let to: TimeOfDay

    /// True when a moment `secondOfDay` seconds past midnight falls inside the window. A window
    /// that wraps midnight (23:00 to 07:00) covers both sides; the end is exclusive, so a sync
    /// due exactly at the end still runs. Equal ends mean no window at all.
    func contains(secondOfDay second: Int) -> Bool {
        let start = from.secondOfDay
        let end = to.secondOfDay
        if start == end { return false }
        if start < end { return second >= start && second < end }
        return second >= start || second < end
    }

    func contains(_ time: TimeOfDay) -> Bool { contains(secondOfDay: time.secondOfDay) }
}

/// What the gate remembers between runs. Sync state, not a setting: not part of a backup.
struct ScheduleState: Equatable, Sendable {
    /// When the last scheduled sync started (absolute time).
    var lastRun: Date?
    /// The configured time that sync ran for, in times mode.
    var lastSlot: LocalDateTime?
    /// When the schedule last changed; times before it do not run.
    var changedAt: Date?
}

enum ScheduleDecision: Equatable, Sendable {
    /// The schedule can never run.
    case never
    /// Run now; `slot` is the configured time it runs for, in times mode.
    case due(slot: LocalDateTime?)
    /// Nothing is due before this moment.
    case wait(until: Date)
}

/// Why automatic syncs are held right now, for the status line.
enum ScheduleHold: Equatable, Sendable {
    case never
    case dayOff
    case quiet(until: TimeOfDay)
}

struct SyncSchedule: Hashable, Sendable {
    static let defaultIntervalMinutes = 60
    /// Android's floor, kept so a schedule means the same on both platforms.
    static let minIntervalMinutes = 15

    var mode: SyncMode = .interval
    var intervalMinutes: Int = SyncSchedule.defaultIntervalMinutes
    /// Times of day for `.times`, in any order; duplicates and order do not matter.
    var times: [TimeOfDay] = []
    /// Days a sync may run. Empty means "no day", which the settings screen warns about.
    var days: Set<Weekday> = Set(Weekday.allCases)
    var quietWindow: QuietWindow?

    /// True when the schedule is a bare interval without filters, as every install had before.
    var isPlainInterval: Bool {
        mode == .interval && quietWindow == nil && days.count == Weekday.allCases.count
    }

    private var hasNothingToRun: Bool {
        days.isEmpty || (mode == .times && times.isEmpty)
    }

    /// True when this schedule can never produce a run, so the UI can warn instead of going
    /// silent: no days, no times, or every time inside the quiet window. Asked from a fixed
    /// Monday midnight, so the answer never depends on when it is asked.
    var isNeverRunning: Bool {
        hasNothingToRun || nextRun(after: LocalDateTime.reference) == nil
    }

    // MARK: - Wall-clock rules

    /// The first wall-clock moment at or after `after` that satisfies mode, weekdays and the
    /// quiet window, or nil when the schedule can never run.
    ///
    /// `lastRun` is the previous scheduled run. Interval mode counts from it; times mode uses
    /// it as a floor of one minute, so a slot that already ran never runs twice.
    func nextRun(after: LocalDateTime, lastRun: LocalDateTime? = nil) -> LocalDateTime? {
        if hasNothingToRun { return nil }
        let floor = lastRun?.adding(seconds: secondsAfterLastRun) ?? after
        return firstAllowed(max(after, floor))
    }

    private var secondsAfterLastRun: Int {
        switch mode {
        case .interval: return intervalMinutes * 60
        case .times: return 60
        }
    }

    /// Walks forward from `candidate` until a moment passes both filters. Interval mode has no
    /// preferred moment, so a quiet hit resumes at the end of the window. Times mode does: a
    /// time inside the window is skipped, not moved, so no sync is invented that was not asked for.
    private func firstAllowed(_ candidate: LocalDateTime) -> LocalDateTime? {
        var current = candidate
        for _ in 0..<SyncSchedule.maxHops {
            if mode == .times {
                guard let scheduled = nextScheduledTime(from: current) else { return nil }
                current = scheduled
            }
            if !days.contains(current.weekday) {
                current = LocalDateTime(day: current.day + 1, second: 0)
                continue
            }
            if let quiet = quietWindow, quiet.contains(secondOfDay: current.second) {
                switch mode {
                case .interval: current = endOfQuietWindow(current, quiet)
                case .times: current = current.adding(seconds: 60)
                }
                continue
            }
            return current
        }
        return nil
    }

    /// The first configured time at or after `from`, looking into the next day if needed.
    private func nextScheduledTime(from: LocalDateTime) -> LocalDateTime? {
        let sorted = Array(Set(times)).sorted()
        guard let first = sorted.first else { return nil }
        if let sameDay = sorted.first(where: { $0.secondOfDay >= from.second }) {
            return LocalDateTime(day: from.day, second: sameDay.secondOfDay)
        }
        return LocalDateTime(day: from.day + 1, second: first.secondOfDay)
    }

    private func endOfQuietWindow(_ current: LocalDateTime, _ quiet: QuietWindow) -> LocalDateTime {
        let sameDay = LocalDateTime(day: current.day, second: quiet.to.secondOfDay)
        return sameDay > current ? sameDay : LocalDateTime(day: current.day + 1, second: quiet.to.secondOfDay)
    }

    /// Every hop moves to the next day, the end of the quiet window or the next configured time,
    /// so a schedule that runs at all is found well within this; it only makes "never" terminate.
    private static let maxHops = 2000

    // MARK: - Real time

    /// The next moment a scheduled sync is due, never before `now`, or nil when it never runs.
    ///
    /// The schedule is wall-clock time and the result a real moment, so the clock changes are
    /// handled the way the Android app does since 1.21.0: the interval is counted in real
    /// minutes, a time in the hour skipped in spring runs that far past the jump (02:30 becomes
    /// 03:30), and a time in the hour repeated in autumn prefers the offset of now, so it is not
    /// taken for the pass that is already over. In times mode the last run is also a wall-clock
    /// floor, so a slot that ran on the first pass of the repeated hour does not run again.
    func nextRunDate(now: Date, lastRun: Date?, timeZone: TimeZone) -> Date? {
        let due = lastRun.map { $0.addingTimeInterval(TimeInterval(secondsAfterLastRun)) }
        let from = due.map { $0 > now ? $0 : now } ?? now
        let wallClockLastRun = mode == .times ? lastRun.map { LocalDateTime($0, in: timeZone) } : nil
        guard let next = nextRun(after: LocalDateTime(from, in: timeZone), lastRun: wallClockLastRun) else {
            return nil
        }
        let date = next.date(in: timeZone, preferringOffsetAt: from)
        return max(date, now)
    }

    // MARK: - The iOS gate

    /// The interval as it is used: never under Android's floor of 15 minutes, whatever a settings
    /// import or an old install stored.
    var effectiveIntervalMinutes: Int { max(intervalMinutes, SyncSchedule.minIntervalMinutes) }

    /// The same schedule with its times sorted and without duplicates, for comparing edits.
    var normalized: SyncSchedule {
        var copy = self
        copy.times = Array(Set(times)).sorted()
        return copy
    }

    /// Whether an automatic sync belongs at `now`, and if not, when the next one does.
    ///
    /// iOS decides when the app runs in the background, so every chance it gives (a HealthKit
    /// wakeup, a background task, opening the app) asks this, and the background task requests
    /// are aimed at the `.wait` date. One function for both, so the question "is it due?" and
    /// the answer "when is it due?" can never disagree: `.due` exactly when that date has passed.
    ///
    /// Interval mode: the interval since the last scheduled sync has passed, within a grace of a
    /// tenth of the interval (at most five minutes), because an hourly wakeup that comes a few
    /// seconds early would otherwise wait for the next one and halve the rate. Then the weekday
    /// filter and the quiet window apply as on Android, resuming at the end of the window.
    ///
    /// Times mode: "not before this time, at the first chance iOS gives". A time counts from the
    /// last scheduled sync, the last time it ran for and the moment the schedule was last
    /// changed, so an edit never runs a time from earlier today. A time iOS gave no chance for
    /// stays owed until the next quiet window or excluded day begins, and is dropped there, so a
    /// 21:00 sync is never moved to the next morning: Android's "skipped, not moved". Several
    /// owed times in one stretch are served by one sync, which records the latest of them.
    func decide(state: ScheduleState, now: Date, timeZone: TimeZone) -> ScheduleDecision {
        if isNeverRunning { return .never }
        let lastRun = state.lastRun.map { min($0, now) }
        switch mode {
        case .interval:
            return decideInterval(lastRun: lastRun, now: now, timeZone: timeZone)
        case .times:
            return decideTimes(state: state, lastRun: lastRun, now: now, timeZone: timeZone)
        }
    }

    private func decideInterval(lastRun: Date?, now: Date, timeZone: TimeZone) -> ScheduleDecision {
        let interval = TimeInterval(effectiveIntervalMinutes * 60)
        let grace = min(5 * 60, interval / 10)
        let earliest = lastRun.map { $0.addingTimeInterval(interval - grace) } ?? now
        let from = max(earliest, now)
        guard let next = firstAllowed(LocalDateTime(from, in: timeZone)) else { return .never }
        let target = next.date(in: timeZone, preferringOffsetAt: from)
        return target <= now ? .due(slot: nil) : .wait(until: target)
    }

    private func decideTimes(state: ScheduleState, lastRun: Date?, now: Date, timeZone: TimeZone) -> ScheduleDecision {
        var floor = LocalDateTime(state.changedAt.map { min($0, now) } ?? now, in: timeZone)
        if let lastRun {
            floor = max(floor, LocalDateTime(lastRun, in: timeZone).adding(seconds: 60))
        }
        if let lastSlot = state.lastSlot {
            floor = max(floor, lastSlot.adding(seconds: 60))
        }
        for _ in 0..<SyncSchedule.maxHops {
            guard let slot = nextRun(after: floor) else { return .never }
            let slotDate = slot.date(in: timeZone, preferringOffsetAt: now)
            if slotDate > now { return .wait(until: slotDate) }
            // Counted from where the time really lands: one in the hour skipped in spring runs
            // that far past the jump (02:30 at 03:30) as on Android, even when quiet hours
            // begin at 03:00, because its configured time was outside them.
            let landed = max(slot, LocalDateTime(slotDate, in: timeZone))
            if let end = endOfAllowedStretch(after: landed),
               now >= end.date(in: timeZone, preferringOffsetAt: slotDate) {
                floor = end
                continue
            }
            var owed = slot
            while let later = nextRun(after: owed.adding(seconds: 60)),
                  later.date(in: timeZone, preferringOffsetAt: now) <= now {
                owed = later
            }
            return .due(slot: owed)
        }
        return .never
    }

    /// The first moment after `slot` at which syncing stops being allowed: the start of the
    /// next quiet window or of the next excluded day. Nil when neither exists.
    private func endOfAllowedStretch(after slot: LocalDateTime) -> LocalDateTime? {
        var candidates: [LocalDateTime] = []
        if let quiet = quietWindow, quiet.from != quiet.to {
            let sameDay = LocalDateTime(day: slot.day, second: quiet.from.secondOfDay)
            candidates.append(sameDay > slot ? sameDay : LocalDateTime(day: slot.day + 1, second: quiet.from.secondOfDay))
        }
        if let offset = (1...7).first(where: { !days.contains(LocalDateTime(day: slot.day + $0, second: 0).weekday) }) {
            candidates.append(LocalDateTime(day: slot.day + offset, second: 0))
        }
        return candidates.min()
    }

    /// Why automatic syncs are held at `now`, for the status line; nil when they are not.
    func hold(at now: Date, timeZone: TimeZone) -> ScheduleHold? {
        if isNeverRunning { return .never }
        let local = LocalDateTime(now, in: timeZone)
        if let quiet = quietWindow, quiet.contains(secondOfDay: local.second) { return .quiet(until: quiet.to) }
        if !days.contains(local.weekday) { return .dayOff }
        return nil
    }

    /// Whether an automatic retry of a queued payload may go out at `now`. Quiet hours hold it;
    /// the weekday filter does not, because the queue drops a payload after seven days and a
    /// one-day-a-week schedule would let it expire unsent.
    func allowsDelivery(at now: Date, timeZone: TimeZone) -> Bool {
        guard let quiet = quietWindow else { return true }
        return !quiet.contains(secondOfDay: LocalDateTime(now, in: timeZone).second)
    }

    // MARK: - Text formats, shared with the Android settings backup

    /// "07:30,21:00" to a sorted list of times; anything unparseable is dropped.
    static func parseTimes(_ text: String) -> [TimeOfDay] {
        Array(Set(text.split(separator: ",").compactMap { TimeOfDay(String($0)) })).sorted()
    }

    static func formatTimes(_ times: [TimeOfDay]) -> String {
        Array(Set(times)).sorted().map(\.text).joined(separator: ",")
    }

    /// "MONDAY,TUESDAY" to a set. Nil (nothing stored yet) means every day; an empty string is
    /// an empty set, so this and `formatDays` are exact inverses.
    static func parseDays(_ text: String?) -> Set<Weekday> {
        guard let text else { return Set(Weekday.allCases) }
        return Set(text.split(separator: ",").compactMap {
            Weekday(rawValue: $0.trimmingCharacters(in: .whitespaces))
        })
    }

    static func formatDays(_ days: Set<Weekday>) -> String {
        Weekday.allCases.filter { days.contains($0) }.map(\.rawValue).joined(separator: ",")
    }
}

/// A wall-clock date and time without a zone, second precision, like java.time's LocalDateTime.
/// Day arithmetic stays in plain integers, so a day is always 24 wall-clock hours here and the
/// clock changes are dealt with only when converting to and from a real `Date`.
struct LocalDateTime: Hashable, Comparable, Sendable {
    /// Days since 1970-01-01.
    let day: Int
    /// Seconds since midnight, 0 up to 86399.
    let second: Int

    init(day: Int, second: Int) {
        let (extraDays, rest) = second.floorDivided(by: 86_400)
        self.day = day + extraDays
        self.second = rest
    }

    /// The wall-clock reading of `date` in `timeZone`.
    init(_ date: Date, in timeZone: TimeZone) {
        let local = Int(date.timeIntervalSince1970.rounded(.down)) + timeZone.secondsFromGMT(for: date)
        self.init(day: 0, second: local)
    }

    /// Monday 2024-01-01 00:00, the fixed moment `isNeverRunning` asks from.
    static let reference = LocalDateTime(day: 19_723, second: 0)

    /// 1970-01-01 was a Thursday.
    var weekday: Weekday {
        let (_, index) = (day + 3).floorDivided(by: 7)
        return Weekday.allCases[index]
    }

    func adding(seconds: Int) -> LocalDateTime { LocalDateTime(day: day, second: second + seconds) }

    /// The real moment this wall-clock reading stands for in `timeZone`, as java.time's
    /// ZonedDateTime.ofLocal does it: a reading in a gap (the hour skipped in spring) moves
    /// forward by the length of the gap, and a reading in an overlap (the hour repeated in
    /// autumn) takes the offset in force at `preferred` when that is one of the two, and
    /// otherwise the earlier one.
    func date(in timeZone: TimeZone, preferringOffsetAt preferred: Date) -> Date {
        let floating = TimeInterval(day * 86_400 + second)
        let before = timeZone.secondsFromGMT(for: Date(timeIntervalSince1970: floating - 86_400))
        let after = timeZone.secondsFromGMT(for: Date(timeIntervalSince1970: floating + 86_400))
        let valid = [before, after].filter { offset in
            timeZone.secondsFromGMT(for: Date(timeIntervalSince1970: floating - TimeInterval(offset))) == offset
        }
        let candidates = Array(Set(valid)).map { Date(timeIntervalSince1970: floating - TimeInterval($0)) }.sorted()
        switch candidates.count {
        case 0:
            return Date(timeIntervalSince1970: floating - TimeInterval(before))
        case 1:
            return candidates[0]
        default:
            let preferredOffset = timeZone.secondsFromGMT(for: preferred)
            return candidates.first {
                timeZone.secondsFromGMT(for: $0) == preferredOffset
            } ?? candidates[0]
        }
    }

    static func < (lhs: LocalDateTime, rhs: LocalDateTime) -> Bool {
        (lhs.day, lhs.second) < (rhs.day, rhs.second)
    }
}

private extension Int {
    /// Division that rounds toward negative infinity, with a remainder that is never negative.
    func floorDivided(by divisor: Int) -> (quotient: Int, remainder: Int) {
        let remainder = ((self % divisor) + divisor) % divisor
        return ((self - remainder) / divisor, remainder)
    }
}
