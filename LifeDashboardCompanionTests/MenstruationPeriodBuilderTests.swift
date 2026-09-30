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

    func testAPeriodCarriesAUuidThatHoldsWhileItGrows() {
        func flow(_ number: Int) -> FlowSample {
            FlowSample(start: day(number), end: day(number), uuid: "flow-\(number)", source: "Cycle App")
        }
        let partial = MenstruationPeriodBuilder.periods(from: [flow(1), flow(2)])
        let whole = MenstruationPeriodBuilder.periods(from: [flow(3), flow(1), flow(2)])
        XCTAssertEqual(partial[0]["uuid"] as? String, "306D9EAF-B128-58ED-BDAB-DD39EF5F157B")
        XCTAssertEqual(whole[0]["uuid"] as? String, partial[0]["uuid"] as? String)
        XCTAssertEqual(whole[0]["source"] as? String, "Cycle App")
        let next = MenstruationPeriodBuilder.periods(from: [flow(1), flow(30)])
        XCTAssertNotEqual(next[0]["uuid"] as? String, next[1]["uuid"] as? String)
        XCTAssertNil(MenstruationPeriodBuilder.periods(from: [flowDay(1)])[0]["uuid"])
    }

    func testAReadOfTheLatestDayStillGetsTheWholePeriod() {
        func flow(_ number: Int) -> FlowSample {
            FlowSample(start: day(number), end: day(number), uuid: "flow-\(number)", source: nil)
        }
        let whole = MenstruationPeriodBuilder.periods(from: [flow(1), flow(2), flow(3)])
        // An incremental sync reads day 3; days 1 and 2 come from the lookback.
        let latest = MenstruationPeriodBuilder.periods(from: [flow(1), flow(2), flow(3)], reaching: day(3))
        XCTAssertEqual(latest.count, 1)
        XCTAssertEqual(latest[0]["uuid"] as? String, whole[0]["uuid"] as? String)
        XCTAssertEqual(latest[0]["start_time"] as? String, day(1).iso8601String)
        // A period over before the read is not sent again.
        XCTAssertTrue(MenstruationPeriodBuilder.periods(from: [flow(1), flow(2)], reaching: day(10)).isEmpty)
    }
}
