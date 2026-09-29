import XCTest
@testable import LifeDashboardCompanion

/// The Android app's SyncScheduleTest, case for case, plus the iOS wakeup gate.
/// 2026-09-14 is a Monday. Summer time in Europe/Amsterdam starts on Sunday 29 March 2026
/// (02:00 becomes 03:00) and ends on Sunday 25 October 2026 (03:00 becomes 02:00).
final class SyncScheduleTests: XCTestCase {

    private let utc = TimeZone(identifier: "UTC")!
    private let amsterdamZone = TimeZone(identifier: "Europe/Amsterdam")!

    /// "2026-09-14T10:05:00" as a wall-clock reading.
    private func at(_ text: String) -> LocalDateTime {
        LocalDateTime(instant(text + "Z"), in: utc)
    }

    private func time(_ text: String) -> TimeOfDay { TimeOfDay(text)! }

    /// An instant written with its offset, so a moment in the repeated hour is unambiguous.
    private func instant(_ text: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)!
    }

    private func minutes(_ value: Int) -> TimeInterval { TimeInterval(value * 60) }

    private func delay(_ schedule: SyncSchedule, now: Date, lastRun: Date? = nil, zone: TimeZone) -> TimeInterval? {
        schedule.nextRunDate(now: now, lastRun: lastRun, timeZone: zone).map { $0.timeIntervalSince(now) }
    }

    // MARK: - Interval mode

    func testIntervalModeCountsFromTheLastRun() {
        let schedule = SyncSchedule(mode: .interval, intervalMinutes: 60)
        XCTAssertEqual(schedule.nextRun(after: at("2026-09-14T10:05:00"), lastRun: at("2026-09-14T10:00:00")), at("2026-09-14T11:00:00"))
    }

    func testAnOverdueIntervalRunIsDueImmediately() {
        let schedule = SyncSchedule(mode: .interval, intervalMinutes: 60)
        XCTAssertEqual(schedule.nextRun(after: at("2026-09-14T14:00:00"), lastRun: at("2026-09-14T10:00:00")), at("2026-09-14T14:00:00"))
    }

    func testWithoutALastRunTheIntervalStartsNow() {
        let schedule = SyncSchedule(mode: .interval, intervalMinutes: 30)
        XCTAssertEqual(schedule.nextRun(after: at("2026-09-14T10:05:00")), at("2026-09-14T10:05:00"))
    }

    func testIntervalModeRefusesToRunTwiceForTheSameDueMoment() {
        let schedule = SyncSchedule(mode: .interval, intervalMinutes: 60)
        XCTAssertEqual(schedule.nextRun(after: at("2026-09-14T11:00:00"), lastRun: at("2026-09-14T11:00:00")), at("2026-09-14T12:00:00"))
    }

    // MARK: - Times mode

    func testTimesModePicksTheNextTimeToday() {
        let schedule = SyncSchedule(mode: .times, times: [time("08:00"), time("21:00")])
        XCTAssertEqual(schedule.nextRun(after: at("2026-09-14T09:30:00")), at("2026-09-14T21:00:00"))
    }

    func testAfterTheLastTimeOfTheDayItRollsOverToTomorrow() {
        let schedule = SyncSchedule(mode: .times, times: [time("08:00"), time("21:00")])
        XCTAssertEqual(schedule.nextRun(after: at("2026-09-14T22:00:00")), at("2026-09-15T08:00:00"))
    }

    func testATimeExactlyNowStillCountsAsTheNextRun() {
        let schedule = SyncSchedule(mode: .times, times: [time("08:00")])
        XCTAssertEqual(schedule.nextRun(after: at("2026-09-14T08:00:00")), at("2026-09-14T08:00:00"))
    }

    func testUnsortedAndDuplicatedTimesBehaveLikeTheSortedDistinctList() {
        let schedule = SyncSchedule(mode: .times, times: [time("21:00"), time("08:00"), time("08:00")])
        XCTAssertEqual(schedule.nextRun(after: at("2026-09-14T07:00:00")), at("2026-09-14T08:00:00"))
    }

    func testARunThatFiredSecondsEarlyIsNotFollowedByASecondOneForTheSameSlot() {
        let schedule = SyncSchedule(mode: .times, times: [time("08:00"), time("21:00")])
        XCTAssertEqual(schedule.nextRun(after: at("2026-09-14T07:59:58"), lastRun: at("2026-09-14T07:59:57")), at("2026-09-14T21:00:00"))
    }

    func testTimesModeWithoutTimesNeverRuns() {
        let schedule = SyncSchedule(mode: .times, times: [])
        XCTAssertTrue(schedule.isNeverRunning)
        XCTAssertNil(schedule.nextRun(after: at("2026-09-14T10:00:00")))
    }

    // MARK: - Weekday filter

    func testAWeekdayFilterSkipsToTheNextAllowedDay() {
        let schedule = SyncSchedule(mode: .times, times: [time("08:00")], days: [.saturday, .sunday])
        XCTAssertEqual(schedule.nextRun(after: at("2026-09-14T10:00:00")), at("2026-09-19T08:00:00"))
    }

    func testTheWeekdayFilterAppliesToIntervalModeToo() {
        let schedule = SyncSchedule(mode: .interval, intervalMinutes: 60, days: Weekday.workdays)
        XCTAssertEqual(schedule.nextRun(after: at("2026-09-19T12:00:00")), at("2026-09-21T00:00:00"))
    }

    func testNoDaysAtAllNeverRuns() {
        let schedule = SyncSchedule(days: [])
        XCTAssertTrue(schedule.isNeverRunning)
        XCTAssertNil(schedule.nextRun(after: at("2026-09-14T10:00:00")))
    }

    func testWeekdaysFollowTheCalendar() {
        XCTAssertEqual(at("2026-09-14T00:00:00").weekday, .monday)
        XCTAssertEqual(at("2026-09-20T23:59:59").weekday, .sunday)
        XCTAssertEqual(at("1969-12-31T12:00:00").weekday, .wednesday)
        XCTAssertEqual(LocalDateTime.reference.weekday, .monday)
    }

    // MARK: - Quiet window

    func testAQuietWindowOverMidnightPushesTheRunToItsEnd() {
        let schedule = SyncSchedule(mode: .interval, intervalMinutes: 60, quietWindow: QuietWindow(from: time("23:00"), to: time("07:00")))
        XCTAssertEqual(schedule.nextRun(after: at("2026-09-14T23:30:00")), at("2026-09-15T07:00:00"))
        XCTAssertEqual(schedule.nextRun(after: at("2026-09-14T02:00:00")), at("2026-09-14T07:00:00"))
    }

    func testAQuietWindowInsideOneDayPushesTheRunToItsEnd() {
        let schedule = SyncSchedule(mode: .interval, intervalMinutes: 60, quietWindow: QuietWindow(from: time("13:00"), to: time("14:00")))
        XCTAssertEqual(schedule.nextRun(after: at("2026-09-14T13:30:00")), at("2026-09-14T14:00:00"))
    }

    func testTheEndOfTheQuietWindowIsNotItselfQuiet() {
        let quiet = QuietWindow(from: time("23:00"), to: time("07:00"))
        XCTAssertTrue(quiet.contains(time("23:00")))
        XCTAssertTrue(quiet.contains(time("03:00")))
        XCTAssertFalse(quiet.contains(time("07:00")))
        XCTAssertFalse(quiet.contains(time("12:00")))
    }

    func testAnEmptyQuietWindowBlocksNothing() {
        let quiet = QuietWindow(from: time("07:00"), to: time("07:00"))
        XCTAssertFalse(quiet.contains(time("07:00")))
        XCTAssertFalse(quiet.contains(time("03:00")))
    }

    func testAScheduledTimeInsideTheQuietWindowIsSkippedNotMoved() {
        let schedule = SyncSchedule(mode: .times, times: [time("03:00"), time("09:00")], quietWindow: QuietWindow(from: time("23:00"), to: time("07:00")))
        XCTAssertEqual(schedule.nextRun(after: at("2026-09-14T02:00:00")), at("2026-09-14T09:00:00"))
    }

    func testATimesScheduleWhoseEveryTimeIsQuietNeverRuns() {
        let schedule = SyncSchedule(mode: .times, times: [time("03:00")], quietWindow: QuietWindow(from: time("23:00"), to: time("07:00")))
        XCTAssertNil(schedule.nextRun(after: at("2026-09-14T02:00:00")))
        XCTAssertTrue(schedule.isNeverRunning)
    }

    func testWeekdayFilterAndQuietWindowCombine() {
        let schedule = SyncSchedule(
            mode: .times,
            times: [time("06:00"), time("08:00")],
            days: Weekday.workdays,
            quietWindow: QuietWindow(from: time("23:00"), to: time("07:00"))
        )
        XCTAssertEqual(schedule.nextRun(after: at("2026-09-18T05:00:00")), at("2026-09-18T08:00:00"))
        XCTAssertEqual(schedule.nextRun(after: at("2026-09-19T05:00:00")), at("2026-09-21T08:00:00"))
    }

    func testABusyTimesScheduleStillTerminates() {
        let everyHalfHour = (0..<48).map { TimeOfDay(hour: $0 / 2, minute: $0 % 2 == 0 ? 0 : 30) }
        let schedule = SyncSchedule(mode: .times, times: everyHalfHour, quietWindow: QuietWindow(from: time("12:30"), to: time("12:00")))
        XCTAssertEqual(schedule.nextRun(after: at("2026-09-14T00:00:00")), at("2026-09-14T12:00:00"))
        XCTAssertFalse(schedule.isNeverRunning)
    }

    // MARK: - Delay

    func testTheDelayIsTheDistanceToTheNextRunAndNeverNegative() {
        let schedule = SyncSchedule(mode: .times, times: [time("08:00")])
        XCTAssertEqual(delay(schedule, now: instant("2026-09-14T07:30:00Z"), zone: utc), minutes(30))
        XCTAssertEqual(delay(schedule, now: instant("2026-09-14T08:00:00Z"), zone: utc), 0)
    }

    func testAScheduleThatNeverRunsHasNoNextDate() {
        XCTAssertNil(SyncSchedule(days: []).nextRunDate(now: instant("2026-09-14T10:00:00Z"), lastRun: nil, timeZone: utc))
    }

    // MARK: - Clock changes (Europe/Amsterdam)

    func testAFixedTimeOnTheNightSummerTimeStartsIsAnHourCloser() {
        let schedule = SyncSchedule(mode: .times, times: [time("07:00")])
        XCTAssertEqual(delay(schedule, now: instant("2026-03-29T00:30:00+01:00"), zone: amsterdamZone), minutes(5 * 60 + 30))
    }

    func testAFixedTimeOnTheNightSummerTimeEndsIsAnHourFurther() {
        let schedule = SyncSchedule(mode: .times, times: [time("07:00")])
        XCTAssertEqual(delay(schedule, now: instant("2026-10-25T00:30:00+02:00"), zone: amsterdamZone), minutes(7 * 60 + 30))
    }

    func testAFixedTimeInTheSkippedHourRunsAtTheSameTimePastTheJump() {
        let schedule = SyncSchedule(mode: .times, times: [time("02:30")])
        XCTAssertEqual(delay(schedule, now: instant("2026-03-29T01:30:00+01:00"), zone: amsterdamZone), minutes(60))
    }

    func testAFixedTimeInTheRepeatedHourIsNotTakenForThePassAlreadyOver() {
        let schedule = SyncSchedule(mode: .times, times: [time("02:30")])
        XCTAssertEqual(delay(schedule, now: instant("2026-10-25T02:10:00+01:00"), zone: amsterdamZone), minutes(20))
    }

    func testAFixedTimeThatRanOnTheFirstPassOfTheRepeatedHourDoesNotRunAgain() {
        let schedule = SyncSchedule(mode: .times, times: [time("02:30")])
        let result = delay(
            schedule,
            now: instant("2026-10-25T02:10:00+01:00"),
            lastRun: instant("2026-10-25T02:30:30+02:00"),
            zone: amsterdamZone
        )
        XCTAssertEqual(result, minutes(24 * 60 + 20))
    }

    func testAnIntervalStaysRealMinutesAcrossBothClockChanges() {
        let schedule = SyncSchedule(mode: .interval, intervalMinutes: 60, quietWindow: QuietWindow(from: time("12:00"), to: time("13:00")))
        let spring = instant("2026-03-29T01:30:00+01:00")
        XCTAssertEqual(delay(schedule, now: spring, lastRun: spring, zone: amsterdamZone), minutes(60))
        let autumn = instant("2026-10-25T02:30:00+02:00")
        XCTAssertEqual(delay(schedule, now: autumn, lastRun: autumn, zone: amsterdamZone), minutes(60))
    }

    // MARK: - The gate (iOS only)

    private func state(lastRun: String? = nil, lastSlot: String? = nil, changedAt: String? = nil) -> ScheduleState {
        ScheduleState(
            lastRun: lastRun.map { instant($0) },
            lastSlot: lastSlot.map { at($0) },
            changedAt: changedAt.map { instant($0) }
        )
    }

    private func decide(_ schedule: SyncSchedule, _ state: ScheduleState, _ now: String, zone: TimeZone? = nil) -> ScheduleDecision {
        schedule.decide(state: state, now: instant(now), timeZone: zone ?? utc)
    }

    func testAPlainIntervalRunsAtOnceAndThenWaitsTheInterval() {
        let schedule = SyncSchedule(mode: .interval, intervalMinutes: 60)
        XCTAssertEqual(decide(schedule, state(), "2026-09-14T10:00:00Z"), .due(slot: nil))
        XCTAssertEqual(
            decide(schedule, state(lastRun: "2026-09-14T10:00:00Z"), "2026-09-14T10:30:00Z"),
            .wait(until: instant("2026-09-14T10:55:00Z"))
        )
        XCTAssertEqual(decide(schedule, state(lastRun: "2026-09-14T10:00:00Z"), "2026-09-14T11:00:00Z"), .due(slot: nil))
    }

    func testAWakeupAFewSecondsEarlyStillCountsForTheInterval() {
        // Without the grace, a wakeup every 59 min 50 s would sync only every other time.
        let schedule = SyncSchedule(mode: .interval, intervalMinutes: 60)
        XCTAssertEqual(decide(schedule, state(lastRun: "2026-09-14T10:00:30Z"), "2026-09-14T11:00:20Z"), .due(slot: nil))
        // The grace is a tenth of the interval: 15 minutes allow 90 seconds, not five minutes.
        let short = SyncSchedule(mode: .interval, intervalMinutes: 15)
        XCTAssertEqual(
            decide(short, state(lastRun: "2026-09-14T10:00:00Z"), "2026-09-14T10:12:00Z"),
            .wait(until: instant("2026-09-14T10:13:30Z"))
        )
    }

    func testAnIntervalBelowTheFloorIsUsedAsFifteenMinutes() {
        let schedule = SyncSchedule(mode: .interval, intervalMinutes: 0)
        XCTAssertEqual(
            decide(schedule, state(lastRun: "2026-09-14T10:00:00Z"), "2026-09-14T10:00:01Z"),
            .wait(until: instant("2026-09-14T10:13:30Z"))
        )
        XCTAssertEqual(SyncSchedule(intervalMinutes: -60).effectiveIntervalMinutes, 15)
    }

    func testALastRunInTheFutureCountsAsNow() {
        // A clock that was wrong once must not hold syncing back for a month.
        let schedule = SyncSchedule(mode: .interval, intervalMinutes: 60)
        XCTAssertEqual(
            decide(schedule, state(lastRun: "2026-10-14T10:00:00Z"), "2026-09-14T10:00:00Z"),
            .wait(until: instant("2026-09-14T10:55:00Z"))
        )
    }

    func testIntervalModeWaitsForTheEndOfTheQuietWindowAndTheNextAllowedDay() {
        let quiet = SyncSchedule(mode: .interval, intervalMinutes: 15, quietWindow: QuietWindow(from: time("23:00"), to: time("07:00")))
        XCTAssertEqual(decide(quiet, state(), "2026-09-14T03:00:00Z"), .wait(until: instant("2026-09-14T07:00:00Z")))
        XCTAssertEqual(decide(quiet, state(), "2026-09-14T07:00:00Z"), .due(slot: nil))
        let workdays = SyncSchedule(mode: .interval, intervalMinutes: 15, days: Weekday.workdays)
        XCTAssertEqual(decide(workdays, state(), "2026-09-19T12:00:00Z"), .wait(until: instant("2026-09-21T00:00:00Z")))
    }

    func testTheGateReadsTheWallClockOfTheGivenZone() {
        // 22:30 UTC is 00:30 the next day in Amsterdam in September, inside 23:00 to 07:00.
        let schedule = SyncSchedule(quietWindow: QuietWindow(from: time("23:00"), to: time("07:00")))
        XCTAssertEqual(decide(schedule, state(), "2026-09-14T22:30:00Z"), .due(slot: nil))
        XCTAssertEqual(
            decide(schedule, state(), "2026-09-14T22:30:00Z", zone: amsterdamZone),
            .wait(until: instant("2026-09-15T07:00:00+02:00"))
        )
    }

    func testATimeIsDueFromItsMomentUntilItRuns() {
        let schedule = SyncSchedule(mode: .times, times: [time("08:00"), time("21:00")])
        let set = state(changedAt: "2026-09-14T06:00:00Z")
        XCTAssertEqual(decide(schedule, set, "2026-09-14T07:59:00Z"), .wait(until: instant("2026-09-14T08:00:00Z")))
        XCTAssertEqual(decide(schedule, set, "2026-09-14T08:00:00Z"), .due(slot: at("2026-09-14T08:00:00")))
        XCTAssertEqual(decide(schedule, set, "2026-09-14T13:40:00Z"), .due(slot: at("2026-09-14T08:00:00")))
    }

    func testATimeThatRanIsNotDueAgainAndTheTargetIsTheNextTime() {
        let schedule = SyncSchedule(mode: .times, times: [time("08:00"), time("21:00")])
        let ran = state(lastRun: "2026-09-14T08:05:00Z", lastSlot: "2026-09-14T08:00:00", changedAt: "2026-09-14T06:00:00Z")
        XCTAssertEqual(decide(schedule, ran, "2026-09-14T09:00:00Z"), .wait(until: instant("2026-09-14T21:00:00Z")))
        XCTAssertEqual(decide(schedule, ran, "2026-09-14T21:10:00Z"), .due(slot: at("2026-09-14T21:00:00")))
    }

    func testAnOwedTimeIsTheBackgroundTargetNotTheNextOne() {
        // The gate and the background request must agree: 08:00 is owed, so the target is now.
        let schedule = SyncSchedule(mode: .times, times: [time("08:00"), time("21:00")])
        let owed = state(lastRun: "2026-09-14T06:00:00Z", changedAt: "2026-09-13T12:00:00Z")
        XCTAssertEqual(decide(schedule, owed, "2026-09-14T09:00:00Z"), .due(slot: at("2026-09-14T08:00:00")))
    }

    func testSeveralMissedTimesAreServedByOneSyncThatRecordsTheLatest() {
        let schedule = SyncSchedule(mode: .times, times: [time("08:00"), time("12:00"), time("16:00")])
        let set = state(changedAt: "2026-09-14T06:00:00Z")
        XCTAssertEqual(decide(schedule, set, "2026-09-14T17:00:00Z"), .due(slot: at("2026-09-14T16:00:00")))
        let after = state(lastRun: "2026-09-14T17:00:00Z", lastSlot: "2026-09-14T16:00:00", changedAt: "2026-09-14T06:00:00Z")
        XCTAssertEqual(decide(schedule, after, "2026-09-14T17:01:00Z"), .wait(until: instant("2026-09-15T08:00:00Z")))
    }

    func testTimesModeWithoutAnyHistoryRunsFromTheFirstTimeAfterItWasSet() {
        let schedule = SyncSchedule(mode: .times, times: [time("08:00")])
        let set = state(changedAt: "2026-09-14T09:00:00Z")
        XCTAssertEqual(decide(schedule, set, "2026-09-14T09:30:00Z"), .wait(until: instant("2026-09-15T08:00:00Z")))
        XCTAssertEqual(decide(schedule, set, "2026-09-15T08:20:00Z"), .due(slot: at("2026-09-15T08:00:00")))
    }

    func testAnEditNeverRunsATimeFromEarlierToday() {
        // Last ran Monday 21:05; at Tuesday 14:00 the user adds 09:00.
        let schedule = SyncSchedule(mode: .times, times: [time("09:00"), time("21:00")])
        let edited = state(lastRun: "2026-09-14T21:05:00Z", lastSlot: "2026-09-14T21:00:00", changedAt: "2026-09-15T14:00:00Z")
        XCTAssertEqual(decide(schedule, edited, "2026-09-15T14:05:00Z"), .wait(until: instant("2026-09-15T21:00:00Z")))
    }

    func testAMissedTimeIsDroppedWhereTheQuietWindowBegins() {
        // 21:00 was never given a chance; at 07:10 it is not moved into the morning.
        let schedule = SyncSchedule(mode: .times, times: [time("09:00"), time("21:00")], quietWindow: QuietWindow(from: time("23:00"), to: time("07:00")))
        let before = state(lastRun: "2026-09-14T09:05:00Z", lastSlot: "2026-09-14T09:00:00", changedAt: "2026-09-01T00:00:00Z")
        XCTAssertEqual(decide(schedule, before, "2026-09-14T22:59:00Z"), .due(slot: at("2026-09-14T21:00:00")))
        XCTAssertEqual(decide(schedule, before, "2026-09-15T07:10:00Z"), .wait(until: instant("2026-09-15T09:00:00Z")))
    }

    func testAMissedTimeIsDroppedWhereAnExcludedDayBegins() {
        // Friday 23:30 is missed; Saturday and Sunday are off, so Monday 00:05 does not run it.
        let schedule = SyncSchedule(mode: .times, times: [time("23:30")], days: Weekday.workdays)
        let before = state(lastRun: "2026-09-17T23:35:00Z", lastSlot: "2026-09-17T23:30:00", changedAt: "2026-09-01T00:00:00Z")
        XCTAssertEqual(decide(schedule, before, "2026-09-18T23:50:00Z"), .due(slot: at("2026-09-18T23:30:00")))
        XCTAssertEqual(decide(schedule, before, "2026-09-21T00:05:00Z"), .wait(until: instant("2026-09-21T23:30:00Z")))
    }

    func testAQuietTimeIsSkippedByTheGateToo() {
        let schedule = SyncSchedule(mode: .times, times: [time("03:00"), time("09:00")], quietWindow: QuietWindow(from: time("23:00"), to: time("07:00")))
        let set = state(changedAt: "2026-09-13T22:00:00Z")
        XCTAssertEqual(decide(schedule, set, "2026-09-14T07:30:00Z"), .wait(until: instant("2026-09-14T09:00:00Z")))
    }

    func testATimeInTheRepeatedHourRunsOnce() {
        // 25 October: 02:30 is first owed on the first pass of the repeated hour. Once it ran,
        // the second pass of 02:30 does not make it due again.
        let schedule = SyncSchedule(mode: .times, times: [time("02:30")])
        let set = state(changedAt: "2026-10-24T12:00:00Z")
        let firstPass = decide(schedule, set, "2026-10-25T02:40:00+02:00", zone: amsterdamZone)
        XCTAssertEqual(firstPass, .due(slot: LocalDateTime(instant("2026-10-25T02:30:00Z"), in: utc)))
        let ran = ScheduleState(
            lastRun: instant("2026-10-25T02:40:00+02:00"),
            lastSlot: LocalDateTime(instant("2026-10-25T02:30:00Z"), in: utc),
            changedAt: instant("2026-10-24T12:00:00Z")
        )
        let secondPass = decide(schedule, ran, "2026-10-25T02:35:00+01:00", zone: amsterdamZone)
        XCTAssertEqual(secondPass, .wait(until: instant("2026-10-26T02:30:00+01:00")))
    }

    func testATimeMovedOutOfTheSkippedHourStillRunsWhenQuietHoursStartInsideIt() {
        // 29 March: 02:30 does not exist and runs at 03:30, even with quiet hours from 03:00.
        let schedule = SyncSchedule(mode: .times, times: [time("02:30")], quietWindow: QuietWindow(from: time("03:00"), to: time("06:00")))
        let set = state(changedAt: "2026-03-28T12:00:00Z")
        XCTAssertEqual(
            decide(schedule, set, "2026-03-29T01:30:00+01:00", zone: amsterdamZone),
            .wait(until: instant("2026-03-29T03:30:00+02:00"))
        )
        if case .due = decide(schedule, set, "2026-03-29T03:30:00+02:00", zone: amsterdamZone) {} else {
            XCTFail("the 02:30 time should run at 03:30")
        }
    }

    func testDueExactlyWhenItsOwnTargetHasPassed() {
        // The property the background requests rely on, over a spread of schedules and moments.
        let schedules = [
            SyncSchedule(mode: .interval, intervalMinutes: 45, quietWindow: QuietWindow(from: time("22:00"), to: time("06:30"))),
            SyncSchedule(mode: .interval, intervalMinutes: 180, days: [.monday, .thursday, .saturday]),
            SyncSchedule(mode: .times, times: [time("07:15"), time("12:00"), time("19:45")], days: Weekday.workdays),
            SyncSchedule(mode: .times, times: [time("02:30"), time("21:00")], quietWindow: QuietWindow(from: time("22:00"), to: time("01:00")))
        ]
        let start = instant("2026-10-23T00:00:00Z")
        for schedule in schedules {
            var state = ScheduleState(changedAt: start.addingTimeInterval(-3600))
            for step in 0..<(4 * 24 * 7) {
                let now = start.addingTimeInterval(TimeInterval(step * 900 + 37))
                switch schedule.decide(state: state, now: now, timeZone: amsterdamZone) {
                case .never:
                    XCTFail("\(schedule) never runs")
                case .wait(let until):
                    XCTAssertGreaterThan(until, now)
                    if case .wait = schedule.decide(state: state, now: until, timeZone: amsterdamZone) {
                        XCTFail("\(schedule) is not due at its own target \(until)")
                    }
                case .due(let slot):
                    // Record the run as the coordinator does; it must not be due again at once.
                    state.lastRun = now
                    state.lastSlot = slot
                    if case .due = schedule.decide(state: state, now: now.addingTimeInterval(1), timeZone: amsterdamZone) {
                        XCTFail("\(schedule) is due twice at \(now)")
                    }
                }
            }
        }
    }

    func testANeverRunningScheduleIsNever() {
        XCTAssertEqual(decide(SyncSchedule(days: []), state(), "2026-09-14T10:00:00Z"), .never)
        XCTAssertEqual(decide(SyncSchedule(mode: .times), state(), "2026-09-14T10:00:00Z"), .never)
    }

    // MARK: - Held states and delivery

    func testHoldExplainsWhyAutomaticSyncsWait() {
        let schedule = SyncSchedule(days: Weekday.workdays, quietWindow: QuietWindow(from: time("23:00"), to: time("07:00")))
        XCTAssertNil(schedule.hold(at: instant("2026-09-14T12:00:00Z"), timeZone: utc))
        XCTAssertEqual(schedule.hold(at: instant("2026-09-14T23:30:00Z"), timeZone: utc), .quiet(until: time("07:00")))
        // Saturday 01:00 is inside the window that began on Friday: quiet first, then the day off.
        XCTAssertEqual(schedule.hold(at: instant("2026-09-19T01:00:00Z"), timeZone: utc), .quiet(until: time("07:00")))
        XCTAssertEqual(schedule.hold(at: instant("2026-09-19T12:00:00Z"), timeZone: utc), .dayOff)
        XCTAssertEqual(SyncSchedule(days: []).hold(at: instant("2026-09-14T12:00:00Z"), timeZone: utc), .never)
        XCTAssertNil(SyncSchedule(quietWindow: QuietWindow(from: time("07:00"), to: time("07:00"))).hold(at: instant("2026-09-14T07:00:00Z"), timeZone: utc))
    }

    func testRetriesWaitForQuietHoursButNotForADayOff() {
        let schedule = SyncSchedule(days: [.monday], quietWindow: QuietWindow(from: time("23:00"), to: time("07:00")))
        XCTAssertFalse(schedule.allowsDelivery(at: instant("2026-09-16T02:00:00Z"), timeZone: utc))
        XCTAssertTrue(schedule.allowsDelivery(at: instant("2026-09-16T12:00:00Z"), timeZone: utc))
        XCTAssertTrue(SyncSchedule(days: []).allowsDelivery(at: instant("2026-09-16T02:00:00Z"), timeZone: utc))
    }

    func testNormalizedIgnoresOrderAndDuplicates() {
        let one = SyncSchedule(mode: .times, times: [time("21:00"), time("08:00"), time("08:00")])
        let two = SyncSchedule(mode: .times, times: [time("08:00"), time("21:00")])
        XCTAssertEqual(one.normalized, two.normalized)
        XCTAssertNotEqual(one.normalized, SyncSchedule(mode: .times, times: [time("08:00")]).normalized)
    }

    // MARK: - Text formats

    func testTimesRoundTripThroughText() {
        XCTAssertEqual(SyncSchedule.formatTimes([time("21:00"), time("08:30")]), "08:30,21:00")
        XCTAssertEqual(SyncSchedule.parseTimes("08:30,21:00"), [time("08:30"), time("21:00")])
    }

    func testParsingTimesDropsWhatItCannotReadAndKeepsTheRest() {
        XCTAssertEqual(SyncSchedule.parseTimes("08:00, nonsense, 25:00, 7:5, +1:30, "), [time("08:00")])
        XCTAssertEqual(SyncSchedule.parseTimes(""), [])
    }

    func testParsingTimesAcceptsSecondsAndNewlinesLikeLocalTimeParse() {
        XCTAssertEqual(SyncSchedule.parseTimes("07:30:00, 08:00\n"), [time("07:30"), time("08:00")])
        XCTAssertNil(TimeOfDay("24:00"))
        XCTAssertNil(TimeOfDay("07:30:60"))
        XCTAssertEqual(TimeOfDay(hour: 25, minute: -3), time("23:00"))
    }

    func testDaysRoundTripThroughTextAndNothingStoredMeansEveryDay() {
        XCTAssertEqual(SyncSchedule.formatDays([.friday, .monday]), "MONDAY,FRIDAY")
        XCTAssertEqual(SyncSchedule.parseDays("MONDAY,FRIDAY"), [.monday, .friday])
        XCTAssertEqual(SyncSchedule.parseDays(nil), Set(Weekday.allCases))
        XCTAssertEqual(SyncSchedule.parseDays(SyncSchedule.formatDays([])), [])
    }
}
