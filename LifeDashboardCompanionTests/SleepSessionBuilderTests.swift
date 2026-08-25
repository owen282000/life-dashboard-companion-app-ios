import XCTest
@testable import LifeDashboardCompanion

final class SleepSessionBuilderTests: XCTestCase {

    private func date(_ minutes: Int) -> Date {
        Date(timeIntervalSince1970: TimeInterval(minutes * 60))
    }

    private func sample(stage: String, startMinute: Int, endMinute: Int) -> SleepStageSample {
        SleepStageSample(
            stage: stage,
            start: date(startMinute),
            end: date(endMinute),
            uuid: "uuid-\(startMinute)",
            source: "TestApp"
        )
    }

    func testAdjacentSamplesFormOneSession() {
        let sessions = SleepSessionBuilder.sessions(from: [
            sample(stage: "light", startMinute: 0, endMinute: 60),
            sample(stage: "deep", startMinute: 60, endMinute: 120),
            sample(stage: "rem", startMinute: 130, endMinute: 180)
        ])

        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0]["duration_seconds"] as? Int, 180 * 60)
        XCTAssertEqual((sessions[0]["stages"] as? [[String: Any]])?.count, 3)
    }

    func testGapLargerThanOneHourSplitsSessions() {
        let sessions = SleepSessionBuilder.sessions(from: [
            sample(stage: "deep", startMinute: 0, endMinute: 60),
            // 2 hour gap
            sample(stage: "light", startMinute: 180, endMinute: 240)
        ])

        XCTAssertEqual(sessions.count, 2)
        XCTAssertEqual(sessions[0]["duration_seconds"] as? Int, 60 * 60)
        XCTAssertEqual(sessions[1]["duration_seconds"] as? Int, 60 * 60)
    }

    func testUnsortedInputIsGroupedCorrectly() {
        let sessions = SleepSessionBuilder.sessions(from: [
            sample(stage: "rem", startMinute: 130, endMinute: 180),
            sample(stage: "light", startMinute: 0, endMinute: 60),
            sample(stage: "deep", startMinute: 60, endMinute: 120)
        ])

        XCTAssertEqual(sessions.count, 1)
        let stages = sessions[0]["stages"] as? [[String: Any]]
        XCTAssertEqual(stages?.first?["stage"] as? String, "light")
        XCTAssertEqual(stages?.last?["stage"] as? String, "rem")
    }

    func testStageCarriesUuidSourceAndDuration() {
        let sessions = SleepSessionBuilder.sessions(from: [
            sample(stage: "deep", startMinute: 0, endMinute: 90)
        ])

        let stage = (sessions[0]["stages"] as? [[String: Any]])?.first
        XCTAssertEqual(stage?["stage"] as? String, "deep")
        XCTAssertEqual(stage?["uuid"] as? String, "uuid-0")
        XCTAssertEqual(stage?["source"] as? String, "TestApp")
        XCTAssertEqual(stage?["duration_seconds"] as? Int, 90 * 60)
    }

    func testEmptyInputProducesNoSessions() {
        XCTAssertTrue(SleepSessionBuilder.sessions(from: []).isEmpty)
    }
}
