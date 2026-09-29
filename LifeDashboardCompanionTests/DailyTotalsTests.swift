import HealthKit
import XCTest
@testable import LifeDashboardCompanion

final class DailyTotalsTests: XCTestCase {

    /// A query that failed, as opposed to one that found no samples.
    private let failed: [String: Double]? = nil

    private let amsterdam = DailyTotals.calendar(timeZone: TimeZone(identifier: "Europe/Amsterdam")!)

    private func date(_ text: String, in calendar: Calendar) -> Date {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.date(from: text)!
    }

    private func metric(_ field: String) -> DailyTotalMetric {
        DailyTotals.metrics.first { $0.field == field }!
    }

    // MARK: - Table

    func testEveryFieldIsInTheAndroidSchema() {
        for metric in DailyTotals.metrics {
            XCTAssertTrue(DailyTotals.schemaFields.contains(metric.field), metric.field)
        }
        XCTAssertEqual(Set(DailyTotals.metrics.map(\.field)).count, DailyTotals.metrics.count)
    }

    func testEveryIdentifierIsACumulativeQuantityInTheRowsUnit() {
        for metric in DailyTotals.metrics {
            XCTAssertFalse(metric.identifiers.isEmpty, metric.field)
            for identifier in metric.identifiers {
                let type = HKQuantityType(identifier)
                XCTAssertEqual(type.aggregationStyle, .cumulative, identifier.rawValue)
                XCTAssertTrue(type.is(compatibleWith: metric.unit), identifier.rawValue)
            }
        }
    }

    func testIdentifiersFollowTheTypesSampleTypes() {
        XCTAssertEqual(metric("steps").identifiers, [.stepCount])
        XCTAssertEqual(metric("distance_meters").identifiers, [.distanceWalkingRunning])
        XCTAssertEqual(metric("active_calories").identifiers, [.activeEnergyBurned])
        XCTAssertEqual(Set(metric("total_calories").identifiers), [.basalEnergyBurned, .activeEnergyBurned])
    }

    // MARK: - Days

    func testASyncCoversTodayAndTheTwoDaysBefore() {
        let now = date("2026-09-30 14:00", in: amsterdam)
        let window = DailyTotals.window(now: now, calendar: amsterdam)
        XCTAssertEqual(window.start, date("2026-09-28 00:00", in: amsterdam))
        XCTAssertEqual(window.end, now)
        XCTAssertEqual(DailyTotals.days(in: window, calendar: amsterdam), ["2026-09-28", "2026-09-29", "2026-09-30"])
    }

    func testJustAfterMidnightStillThreeDays() {
        let now = date("2026-09-30 00:00", in: amsterdam).addingTimeInterval(30)
        let window = DailyTotals.window(now: now, calendar: amsterdam)
        XCTAssertEqual(DailyTotals.days(in: window, calendar: amsterdam), ["2026-09-28", "2026-09-29", "2026-09-30"])
    }

    func testDaylightSavingDaysKeepTheirRealMidnights() {
        // 2026-03-29 has 23 hours in Amsterdam and 2026-10-25 has 25.
        let spring = DailyTotals.window(now: date("2026-03-30 12:00", in: amsterdam), calendar: amsterdam)
        XCTAssertEqual(DailyTotals.days(in: spring, calendar: amsterdam), ["2026-03-28", "2026-03-29", "2026-03-30"])
        XCTAssertEqual(spring.duration, (24 + 23 + 12) * 3600)

        let autumn = DailyTotals.window(now: date("2026-10-26 12:00", in: amsterdam), calendar: amsterdam)
        XCTAssertEqual(DailyTotals.days(in: autumn, calendar: amsterdam), ["2026-10-24", "2026-10-25", "2026-10-26"])
        XCTAssertEqual(autumn.duration, (24 + 25 + 12) * 3600)
    }

    func testAZoneWhoseDaylightSavingStartsAtMidnightNamesEveryDayOnce() {
        // Chile moves its clocks at midnight in September, so one day starts at 01:00.
        let santiago = DailyTotals.calendar(timeZone: TimeZone(identifier: "America/Santiago")!)
        let interval = DateInterval(start: date("2026-09-04 12:00", in: santiago), end: date("2026-09-08 12:00", in: santiago))
        XCTAssertEqual(
            DailyTotals.days(in: interval, calendar: santiago),
            ["2026-09-04", "2026-09-05", "2026-09-06", "2026-09-07", "2026-09-08"]
        )
    }

    func testTheDateFollowsTheDevicesTimeZone() {
        let instant = Date(timeIntervalSince1970: 1_790_000_000)
        let kiritimati = DailyTotals.calendar(timeZone: TimeZone(identifier: "Pacific/Kiritimati")!)
        let pagoPago = DailyTotals.calendar(timeZone: TimeZone(identifier: "Pacific/Pago_Pago")!)
        XCTAssertNotEqual(DailyTotals.dateString(instant, calendar: kiritimati), DailyTotals.dateString(instant, calendar: pagoPago))
    }

    func testTheDateIsGregorianWhateverTheUsersCalendar() {
        let instant = date("2026-09-30 12:00", in: amsterdam)
        var buddhist = Calendar(identifier: .buddhist)
        buddhist.timeZone = amsterdam.timeZone
        XCTAssertEqual(buddhist.component(.year, from: instant), 2569)

        XCTAssertEqual(DailyTotals.calendar().identifier, .gregorian)
        XCTAssertEqual(DailyTotals.dateString(instant, calendar: amsterdam), "2026-09-30")
    }

    func testTheLastDaysOfDecemberKeepTheirYear() {
        XCTAssertEqual(DailyTotals.dateString(date("2026-12-29 12:00", in: amsterdam), calendar: amsterdam), "2026-12-29")
        XCTAssertEqual(DailyTotals.dateString(date("2026-12-31 23:59", in: amsterdam), calendar: amsterdam), "2026-12-31")
    }

    // MARK: - Backfill windows

    func testABackfillWindowAsksForEveryWholeDayItTouches() {
        let window = DateInterval(start: date("2026-09-01 10:00", in: amsterdam), end: date("2026-09-08 10:00", in: amsterdam))
        let days = DailyTotals.wholeDays(touching: window, now: date("2026-09-30 12:00", in: amsterdam), calendar: amsterdam)
        XCTAssertEqual(days?.start, date("2026-09-01 00:00", in: amsterdam))
        XCTAssertEqual(days?.end, date("2026-09-09 00:00", in: amsterdam))
        XCTAssertEqual(days.map { DailyTotals.days(in: $0, calendar: amsterdam).count }, 8)
    }

    func testABackfillWindowStopsAtNow() {
        let now = date("2026-09-30 12:00", in: amsterdam)
        let window = DateInterval(start: date("2026-09-28 10:00", in: amsterdam), end: now)
        XCTAssertEqual(DailyTotals.wholeDays(touching: window, now: now, calendar: amsterdam)?.end, now)
    }

    func testABackfillWindowInTheFutureAsksForNothing() {
        let now = date("2026-09-30 12:00", in: amsterdam)
        let window = DateInterval(start: date("2026-10-02 00:00", in: amsterdam), end: date("2026-10-03 00:00", in: amsterdam))
        XCTAssertNil(DailyTotals.wholeDays(touching: window, now: now, calendar: amsterdam))
    }

    // MARK: - Entries

    func testEntriesCarryEveryFieldWithItsType() throws {
        let entries = DailyTotals.entries(days: ["2026-09-30"], sums: [
            .stepCount: ["2026-09-30": 8421.6],
            .distanceWalkingRunning: ["2026-09-30": 6210.4],
            .activeEnergyBurned: ["2026-09-30": 412.0],
            .basalEnergyBurned: ["2026-09-30": 1819.5]
        ])
        XCTAssertEqual(entries.count, 1)
        let entry = entries[0]
        XCTAssertEqual(entry["date"] as? String, "2026-09-30")
        XCTAssertEqual(entry["steps"] as? Int, 8422)
        XCTAssertEqual(entry["distance_meters"] as? Double, 6210.4)
        XCTAssertEqual(entry["active_calories"] as? Double, 412.0)
        XCTAssertEqual(entry["total_calories"] as? Double, 2231.5)
        XCTAssertTrue(Set(entry.keys).isSubset(of: DailyTotals.schemaFields))

        let body = try JSONSerialization.data(withJSONObject: [DailyTotals.payloadKey: entries], options: [.sortedKeys])
        XCTAssertTrue(String(bytes: body, encoding: .utf8)?.contains("\"steps\":8422") == true)
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: [[String: Any]]])
        XCTAssertEqual(parsed[DailyTotals.payloadKey]?.first?["distance_meters"] as? Double, 6210.4)
    }

    func testADayWithoutSamplesLeavesTheFieldOut() {
        let entries = DailyTotals.entries(days: ["2026-09-29", "2026-09-30"], sums: [
            .stepCount: ["2026-09-29": 5000, "2026-09-30": 1200],
            .distanceWalkingRunning: ["2026-09-30": 800]
        ])
        XCTAssertEqual(entries.count, 2)
        XCTAssertNil(entries[0]["distance_meters"])
        XCTAssertEqual(entries[1]["distance_meters"] as? Double, 800)
    }

    func testADayWithoutAnyFieldIsDropped() {
        let entries = DailyTotals.entries(days: ["2026-09-28", "2026-09-29", "2026-09-30"], sums: [
            .stepCount: ["2026-09-28": 3000, "2026-09-30": 1200]
        ])
        XCTAssertEqual(entries.map { $0["date"] as? String }, ["2026-09-28", "2026-09-30"])
    }

    func testNothingAtAllGivesNoEntries() {
        XCTAssertTrue(DailyTotals.entries(days: ["2026-09-30"], sums: [.stepCount: [:]]).isEmpty)
        XCTAssertTrue(DailyTotals.entries(days: ["2026-09-30"], sums: [:]).isEmpty)
    }

    func testAFailedQueryLeavesItsFieldOutOnEveryDay() {
        let entries = DailyTotals.entries(days: ["2026-09-30"], sums: [
            .stepCount: ["2026-09-30": 1200],
            .distanceWalkingRunning: failed
        ])
        XCTAssertEqual(entries.count, 1)
        XCTAssertNil(entries[0]["distance_meters"])
        XCTAssertEqual(entries[0]["steps"] as? Int, 1200)
    }

    func testOnlyTheRowsPassedInAreSent() {
        let entries = DailyTotals.entries(
            days: ["2026-09-30"],
            sums: [.stepCount: ["2026-09-30": 1200], .activeEnergyBurned: ["2026-09-30": 300]],
            metrics: DailyTotals.metrics.filter { $0.type == .steps }
        )
        XCTAssertEqual(Set(entries[0].keys), ["date", "steps"])
    }

    func testNonFiniteSumsAreDropped() {
        let entries = DailyTotals.entries(days: ["2026-09-30"], sums: [
            .stepCount: ["2026-09-30": .nan],
            .activeEnergyBurned: ["2026-09-30": .infinity]
        ])
        XCTAssertTrue(entries.isEmpty)
    }

    // MARK: - Total calories

    func testTotalCaloriesNeedsRestingEnergy() {
        let entries = DailyTotals.entries(days: ["2026-09-30"], sums: [
            .activeEnergyBurned: ["2026-09-30": 412],
            .basalEnergyBurned: [:]
        ])
        XCTAssertEqual(entries[0]["active_calories"] as? Double, 412)
        XCTAssertNil(entries[0]["total_calories"])
    }

    func testTotalCaloriesWithRestingEnergyOnly() {
        let entries = DailyTotals.entries(days: ["2026-09-30"], sums: [
            .activeEnergyBurned: [:],
            .basalEnergyBurned: ["2026-09-30": 1650]
        ])
        XCTAssertEqual(entries[0]["total_calories"] as? Double, 1650)
        XCTAssertNil(entries[0]["active_calories"])
    }

    func testTotalCaloriesIsLeftOutWhenEitherHalfFailed() {
        let activeFailed = DailyTotals.entries(days: ["2026-09-30"], sums: [
            .activeEnergyBurned: failed,
            .basalEnergyBurned: ["2026-09-30": 1650]
        ])
        XCTAssertTrue(activeFailed.isEmpty)

        let restingFailed = DailyTotals.entries(days: ["2026-09-30"], sums: [
            .activeEnergyBurned: ["2026-09-30": 412],
            .basalEnergyBurned: failed
        ])
        XCTAssertNil(restingFailed[0]["total_calories"])
        XCTAssertEqual(restingFailed[0]["active_calories"] as? Double, 412)
    }

    // MARK: - Retry queue

    func testAQueuedPayloadLosesOnlyTheDayItWasBuiltOn() {
        let payload: [String: Any] = [
            "source": "healthkit_ios",
            DailyTotals.payloadKey: [
                ["date": "2026-09-29", "steps": 9000],
                ["date": "2026-09-30", "steps": 4000]
            ]
        ]
        let queued = DailyTotals.forQueue(payload, builtOn: "2026-09-30")
        let entries = queued[DailyTotals.payloadKey] as? [[String: Any]]
        XCTAssertEqual(entries?.map { $0["date"] as? String }, ["2026-09-29"])
        XCTAssertEqual(queued["source"] as? String, "healthkit_ios")
    }

    func testAQueuedPayloadWithOnlyTodayLosesTheKey() {
        let payload: [String: Any] = [DailyTotals.payloadKey: [["date": "2026-09-30", "steps": 4000]]]
        XCTAssertNil(DailyTotals.forQueue(payload, builtOn: "2026-09-30")[DailyTotals.payloadKey])
    }

    func testAPayloadWithoutTotalsIsQueuedAsItIs() {
        let payload: [String: Any] = ["source": "healthkit_ios"]
        XCTAssertEqual(DailyTotals.forQueue(payload, builtOn: "2026-09-30").count, 1)
    }

    // MARK: - Reader

    func testNoTotalTypeEnabledReadsNothing() async {
        let window = DailyTotals.window(calendar: amsterdam)
        let totals = await HealthKitManager.shared.readDailyTotals(in: window, enabledTypes: [.heartRate, .sleep], calendar: amsterdam)
        XCTAssertTrue(totals.isEmpty)
    }
}
