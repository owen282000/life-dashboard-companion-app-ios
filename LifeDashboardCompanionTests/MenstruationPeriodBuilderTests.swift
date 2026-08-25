import XCTest
@testable import LifeDashboardCompanion

final class MenstruationPeriodBuilderTests: XCTestCase {

    private func day(_ number: Int) -> Date {
        Date(timeIntervalSince1970: TimeInterval(number) * 86_400)
    }

    private func flowDay(_ number: Int) -> FlowSample {
        FlowSample(start: day(number), end: day(number))
    }

    func testConsecutiveFlowDaysFormOnePeriod() {
        let periods = MenstruationPeriodBuilder.periods(from: [
            flowDay(1), flowDay(2), flowDay(3), flowDay(4)
        ])

        XCTAssertEqual(periods.count, 1)
        XCTAssertEqual(periods[0]["start_time"] as? String, day(1).iso8601String)
        XCTAssertEqual(periods[0]["end_time"] as? String, day(4).iso8601String)
    }

    func testSingleMissedLoggingDayStaysOnePeriod() {
        let periods = MenstruationPeriodBuilder.periods(from: [
            flowDay(1), flowDay(2), flowDay(4)
        ])

        XCTAssertEqual(periods.count, 1)
    }

    func testLargeGapSplitsPeriods() {
        let periods = MenstruationPeriodBuilder.periods(from: [
            flowDay(1), flowDay(2), flowDay(30), flowDay(31)
        ])

        XCTAssertEqual(periods.count, 2)
        XCTAssertEqual(periods[1]["start_time"] as? String, day(30).iso8601String)
    }

    func testUnsortedInputIsHandled() {
        let periods = MenstruationPeriodBuilder.periods(from: [
            flowDay(3), flowDay(1), flowDay(2)
        ])

        XCTAssertEqual(periods.count, 1)
        XCTAssertEqual(periods[0]["start_time"] as? String, day(1).iso8601String)
        XCTAssertEqual(periods[0]["end_time"] as? String, day(3).iso8601String)
    }

    func testEmptyInputProducesNoPeriods() {
        XCTAssertTrue(MenstruationPeriodBuilder.periods(from: []).isEmpty)
    }
}
