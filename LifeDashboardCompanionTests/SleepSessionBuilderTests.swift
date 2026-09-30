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

    func testASessionCarriesAStableUuidOfItsOwn() {
        let night = [
            sample(stage: "light", startMinute: 0, endMinute: 60),
            sample(stage: "deep", startMinute: 60, endMinute: 120)
        ]
        let first = SleepSessionBuilder.sessions(from: night)[0]["uuid"] as? String
        let again = SleepSessionBuilder.sessions(from: night.reversed())[0]["uuid"] as? String

        XCTAssertNotNil(first)
        XCTAssertEqual(first, again)
        XCTAssertNotNil(first.flatMap(UUID.init(uuidString:)))
        XCTAssertFalse(["uuid-0", "uuid-60"].contains(first ?? ""))
    }

    func testTheUuidHoldsWhileTheNightGrows() {
        // A sync during the night, then the whole night: Home Assistant must see one session.
        let partial = SleepSessionBuilder.sessions(from: [sample(stage: "light", startMinute: 0, endMinute: 60)])
        let whole = SleepSessionBuilder.sessions(from: [
            sample(stage: "light", startMinute: 0, endMinute: 60),
            sample(stage: "rem", startMinute: 60, endMinute: 150)
        ])
        XCTAssertEqual(partial[0]["uuid"] as? String, whole[0]["uuid"] as? String)
    }

    func testDifferentNightsGetDifferentUuids() {
        let sessions = SleepSessionBuilder.sessions(from: [
            sample(stage: "deep", startMinute: 0, endMinute: 60),
            sample(stage: "light", startMinute: 1440, endMinute: 1500)
        ])
        XCTAssertNotEqual(sessions[0]["uuid"] as? String, sessions[1]["uuid"] as? String)
    }

    func testNoStageUuidMeansNoSessionUuid() {
        let sessions = SleepSessionBuilder.sessions(from: [
            SleepStageSample(stage: "deep", start: date(0), end: date(60), uuid: nil, source: nil)
        ])
        XCTAssertNil(sessions[0]["uuid"])
    }

    func testStagesStartingTogetherPickTheSameEarliestStage() {
        let one = SleepStageSample(stage: "awake", start: date(0), end: date(10), uuid: "B", source: nil)
        let two = SleepStageSample(stage: "light", start: date(0), end: date(30), uuid: "A", source: nil)
        XCTAssertEqual(SleepSessionBuilder.sessionUuid(for: [one, two]), SleepSessionBuilder.sessionUuid(for: [two, one]))
    }

    func testTheSessionUuidIsTheSameAs14Sent() {
        let session = SleepSessionBuilder.sessions(from: [sample(stage: "deep", startMinute: 0, endMinute: 60)])[0]
        XCTAssertEqual(session["uuid"] as? String, "4A9244F2-2D36-5EAC-BAAB-40C84CE9C13C")
    }

    func testASessionNamesTheSourceThatRecordedMostOfTheNight() {
        let stages = [
            SleepStageSample(stage: "in_bed", start: date(0), end: date(480), uuid: "A", source: "iPhone"),
            SleepStageSample(stage: "light", start: date(10), end: date(200), uuid: "B", source: "Watch"),
            SleepStageSample(stage: "deep", start: date(200), end: date(260), uuid: "C", source: "Watch"),
            SleepStageSample(stage: "awake", start: date(260), end: date(270), uuid: "D", source: "Other")
        ]
        XCTAssertEqual(SleepSessionBuilder.sessions(from: stages)[0]["source"] as? String, "Watch")
        XCTAssertEqual(SleepSessionBuilder.sessions(from: Array(stages.prefix(1)))[0]["source"] as? String, "iPhone")
        let unnamed = SleepStageSample(stage: "deep", start: date(0), end: date(60), uuid: nil, source: nil)
        XCTAssertNil(SleepSessionBuilder.sessions(from: [unnamed])[0]["source"])
    }

    func testEmptyInputProducesNoSessions() {
        XCTAssertTrue(SleepSessionBuilder.sessions(from: []).isEmpty)
    }
}
