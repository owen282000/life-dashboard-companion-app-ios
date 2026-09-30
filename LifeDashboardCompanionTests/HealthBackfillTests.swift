import XCTest
@testable import LifeDashboardCompanion

/// A HealthKit stand-in: one sample per start date, sliced with the real SyncLimits.sliceEnd
/// and the real per-type caps, so the engine is exercised the way it runs on a phone.
private actor FakeReader: BackfillReading {
    var samples: [HealthDataType: [(uuid: String, start: Date)]] = [:]
    var locked = false
    var failing: HealthDataType?
    var inexact: Set<HealthDataType> = []
    private(set) var reads = 0

    func add(_ type: HealthDataType, count: Int, from start: Date, every seconds: TimeInterval, prefix: String) {
        samples[type, default: []] += (0..<count).map { ("\(prefix)\($0)", start.addingTimeInterval(TimeInterval($0) * seconds)) }
    }

    func setLocked(_ value: Bool) { locked = value }
    func setFailing(_ type: HealthDataType?) { failing = type }
    func setInexact(_ type: HealthDataType) { inexact.insert(type) }

    func canRead() async -> Bool { !locked }

    func readSlice(_ type: HealthDataType, from cursor: Date, window: DateInterval, rangeEnd: Date) async throws -> BackfillSlice {
        reads += 1
        if type == failing { throw NSError(domain: "fake", code: 1) }
        let limit = SyncLimits.maxRecordsPerSync(for: type)
        let inRange = (samples[type] ?? []).filter { $0.start >= cursor && $0.start < window.end }.sorted { $0.start < $1.start }
        let slice = SyncLimits.sliceEnd(probedStartDates: inRange.prefix(limit).map(\.start), limit: limit, from: cursor, to: window.end)
        let taken = inRange.filter { $0.start < slice.end }.map { ["uuid": $0.uuid, "time": $0.start.iso8601String] }
        let records: [(String, Any)] = taken.isEmpty ? [] : [(type.rawValue.lowercased(), taken)]
        return BackfillSlice(records: records, end: slice.end, exact: slice.exact && !inexact.contains(type))
    }
}

private actor FakeSink: BackfillDelivering {
    private(set) var sent: [Data] = []
    var failAt: Int?

    func setFailAt(_ index: Int?) { failAt = index }

    func deliver(_ body: Data, recordCount: Int) async -> Bool {
        if let failAt, sent.count == failAt { return false }
        sent.append(body)
        return true
    }

    func uuids(_ key: String) -> [String] {
        decoded(sent).flatMap { ($0[key] as? [[String: Any]] ?? []).compactMap { $0["uuid"] as? String } }
    }
}

private func decoded(_ bodies: [Data]) -> [[String: Any]] {
    bodies.map { (try? JSONSerialization.jsonObject(with: $0) as? [String: Any]) ?? [:] }
}

private actor Counter {
    private(set) var value = 0
    func increment() { value += 1 }
}

final class HealthBackfillTests: XCTestCase {

    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000.75)

    private func engine(
        _ reader: FakeReader,
        _ sink: FakeSink,
        types: [HealthDataType],
        stop: BackfillJob.PauseReason? = nil
    ) -> BackfillEngine {
        let fixed = now
        return BackfillEngine(
            reader: reader,
            sink: sink,
            appVersion: "9.9.9",
            enabledTypes: { types },
            shouldStop: { stop },
            now: { fixed }
        )
    }

    private func job(days: Int) -> BackfillJob {
        BackfillJob(days: days, range: BackfillPlan.range(days: days, now: now), now: now)
    }

    // MARK: - Plan

    func testRangesSplitIntoAndroidsThreeDayWindows() {
        XCTAssertEqual(job(days: 30).windowCount, 10)
        XCTAssertEqual(job(days: 90).windowCount, 30)
        XCTAssertEqual(job(days: 365).windowCount, 122)
    }

    func testWindowsAreContiguousOldestFirstAndEndAtTheFlooredStart() {
        let range = BackfillPlan.range(days: 365, now: now)
        XCTAssertEqual(range.end.timeIntervalSinceReferenceDate, 800_000_000)
        var expectedStart = range.start
        for index in 0..<BackfillPlan.windowCount(of: range) {
            let window = BackfillPlan.window(index, of: range)
            XCTAssertEqual(window.start, expectedStart)
            expectedStart = window.end
        }
        XCTAssertEqual(expectedStart, range.end)
        // 365 days is 121 whole windows and a last one of two days.
        XCTAssertEqual(BackfillPlan.window(121, of: range).duration, 2 * 86_400)
    }

    func testRangeStopsAtTheEarliestPermittedSample() {
        let earliest = now.addingTimeInterval(-10 * 86_400)
        let range = BackfillPlan.range(days: 90, now: now, earliestPermitted: earliest)
        XCTAssertEqual(range.start, earliest)
        XCTAssertEqual(BackfillPlan.windowCount(of: range), 4)
    }

    func testASleepSessionBelongsToTheWindowItEndsIn() {
        let range = BackfillPlan.range(days: 9, now: now)
        let first = BackfillPlan.window(0, of: range)
        let second = BackfillPlan.window(1, of: range)
        let end = first.end.addingTimeInterval(1800)
        XCTAssertFalse(BackfillPlan.ownsSession(endingAt: end, window: first, rangeEnd: range.end))
        XCTAssertTrue(BackfillPlan.ownsSession(endingAt: end, window: second, rangeEnd: range.end))
        XCTAssertTrue(BackfillPlan.ownsSession(endingAt: first.end.addingTimeInterval(-1), window: first, rangeEnd: range.end))
    }

    func testASessionThatMayStillBeGoingOnIsLeftToTheSync() {
        let range = BackfillPlan.range(days: 9, now: now)
        let last = BackfillPlan.window(2, of: range)
        XCTAssertFalse(BackfillPlan.ownsSession(endingAt: range.end.addingTimeInterval(-600), window: last, rangeEnd: range.end))
        XCTAssertTrue(BackfillPlan.ownsSession(endingAt: range.end.addingTimeInterval(-7200), window: last, rangeEnd: range.end))
    }

    func testAPeriodBelongsToTheWindowItStartsIn() {
        let window = DateInterval(start: now, duration: BackfillPlan.windowLength)
        XCTAssertTrue(BackfillPlan.ownsPeriod(startingAt: now, window: window))
        XCTAssertFalse(BackfillPlan.ownsPeriod(startingAt: window.end, window: window))
    }

    // MARK: - Payload

    func testPayloadCarriesAndroidsBackfillFieldsAndNeverClaimsCompleteness() throws {
        let window = DateInterval(start: Date(timeIntervalSince1970: 1_700_000_000), duration: BackfillPlan.windowLength)
        let body = try XCTUnwrap(BackfillPayload.body(
            records: [("steps", [["count": 12]])],
            window: window,
            extras: ["daily_totals": [["date": "2023-11-14"]]],
            appVersion: "9.9.9",
            now: now
        ))
        let text = try XCTUnwrap(String(data: body, encoding: .utf8))
        XCTAssertTrue(text.contains("\"backfill\":true"))
        XCTAssertTrue(text.contains("\"window_complete\":false"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["window_start"] as? String, "2023-11-14T22:13:20Z")
        XCTAssertEqual(json["window_end"] as? String, "2023-11-17T22:13:20Z")
        XCTAssertEqual(json["source"] as? String, "healthkit_ios")
        XCTAssertNotNil(json["daily_totals"])
        XCTAssertNotNil(json["steps"])
        for key in ["sequence", "deleted_records", "deletions_unavailable", "writeback", "_diagnostics"] {
            XCTAssertNil(json[key], key)
        }
    }

    // MARK: - Engine

    func testADenseTypeDrainsInChunksWithEveryRecordOnce() async {
        let reader = FakeReader()
        let sink = FakeSink()
        let job = job(days: 3)
        await reader.add(.heartRate, count: 2500, from: job.rangeStart, every: 60, prefix: "hr")
        await reader.add(.weight, count: 3, from: job.rangeStart, every: 3600, prefix: "w")

        let final = await engine(reader, sink, types: [.heartRate, .weight]).run(job)

        XCTAssertEqual(final.status, .done)
        XCTAssertEqual(final.recordsSent, 2503)
        let heartRates = await sink.uuids("heart_rate")
        XCTAssertEqual(heartRates, (0..<2500).map { "hr\($0)" })
        let bodies = decoded(await sink.sent)
        XCTAssertEqual(bodies.count, 3)
        XCTAssertTrue(bodies.allSatisfy { ($0["heart_rate"] as? [Any])?.count ?? 0 < 1000 })
        // Weight is done after the first chunk and is not read again.
        let weights = await sink.uuids("weight")
        XCTAssertEqual(weights, ["w0", "w1", "w2"])
    }

    func testAnEmptyWindowStillSendsOnePayload() async {
        let reader = FakeReader()
        let sink = FakeSink()
        let final = await engine(reader, sink, types: [.steps]).run(job(days: 9))
        XCTAssertEqual(final.status, .done)
        let bodies = decoded(await sink.sent)
        XCTAssertEqual(bodies.count, 3)
        XCTAssertTrue(bodies.allSatisfy { $0["steps"] == nil && $0["backfill"] as? Bool == true })
    }

    func testAFailedDeliveryStopsAndAResumeSendsThatWindowAgain() async {
        let reader = FakeReader()
        let sink = FakeSink()
        let start = job(days: 6)
        await reader.add(.heartRate, count: 1500, from: start.rangeStart.addingTimeInterval(4 * 86_400), every: 60, prefix: "hr")
        await sink.setFailAt(2)  // window 0 is one empty payload, window 1 fails on its second chunk

        let failed = await engine(reader, sink, types: [.heartRate]).run(start)
        XCTAssertEqual(failed.status, .failed)
        XCTAssertEqual(failed.failure, .delivery)
        XCTAssertEqual(failed.nextWindow, 1)
        XCTAssertEqual(failed.recordsSent, 0)

        await sink.setFailAt(nil)
        let resumed = await engine(reader, sink, types: [.heartRate]).run(failed)
        XCTAssertEqual(resumed.status, .done)
        XCTAssertEqual(resumed.recordsSent, 1500)
        let sent = await sink.uuids("heart_rate")
        XCTAssertEqual(Set(sent).count, 1500)
    }

    func testALockedPhoneSendsNothingAndPauses() async {
        let reader = FakeReader()
        let sink = FakeSink()
        await reader.setLocked(true)
        let final = await engine(reader, sink, types: [.steps]).run(job(days: 3))
        XCTAssertEqual(final.status, .paused)
        XCTAssertEqual(final.pauseReason, .locked)
        let bodies = decoded(await sink.sent)
        XCTAssertTrue(bodies.isEmpty)
    }

    func testAReadErrorStopsAndNamesTheType() async {
        let reader = FakeReader()
        let sink = FakeSink()
        await reader.setFailing(.weight)
        let final = await engine(reader, sink, types: [.steps, .weight]).run(job(days: 3))
        XCTAssertEqual(final.status, .failed)
        XCTAssertEqual(final.failure, .read(type: "WEIGHT"))
        let bodies = decoded(await sink.sent)
        XCTAssertTrue(bodies.isEmpty)
    }

    func testAStopRequestPausesBeforeTheNextWindow() async {
        let reader = FakeReader()
        let sink = FakeSink()
        let final = await engine(reader, sink, types: [.steps], stop: .user).run(job(days: 9))
        XCTAssertEqual(final.status, .paused)
        XCTAssertEqual(final.pauseReason, .user)
        XCTAssertEqual(final.nextWindow, 0)
    }

    func testAWindowThatCannotBeReadInFullIsCountedAndTheRunGoesOn() async {
        let reader = FakeReader()
        let sink = FakeSink()
        await reader.setInexact(.steps)
        let final = await engine(reader, sink, types: [.steps]).run(job(days: 6))
        XCTAssertEqual(final.status, .done)
        XCTAssertEqual(final.truncatedWindows, 2)
    }

    func testWindowExtrasAreAskedOnceAndGoInEveryChunk() async {
        let reader = FakeReader()
        let sink = FakeSink()
        let calls = Counter()
        let start = job(days: 3)
        await reader.add(.steps, count: 2000, from: start.rangeStart, every: 60, prefix: "s")
        var engine = engine(reader, sink, types: [.steps])
        engine.windowExtras = { _ in
            await calls.increment()
            return BackfillExtras(fields: ["daily_totals": [["date": "x"]]])
        }
        _ = await engine.run(start)
        let asked = await calls.value
        XCTAssertEqual(asked, 1)
        let bodies = decoded(await sink.sent)
        XCTAssertGreaterThan(bodies.count, 1)
        XCTAssertTrue(bodies.allSatisfy { $0["daily_totals"] != nil })
    }

    func testEachDeliveredWindowIsReportedForSaving() async {
        let reader = FakeReader()
        let sink = FakeSink()
        let windows = Counter()
        var engine = engine(reader, sink, types: [.steps])
        engine.onWindowDone = { _, _ in await windows.increment() }
        _ = await engine.run(job(days: 9))
        let count = await windows.value
        XCTAssertEqual(count, 3)
    }

    // MARK: - Job

    func testJobSurvivesTheStoreAndABrokenOneIsDropped() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "HealthBackfillTests"))
        defaults.removePersistentDomain(forName: "HealthBackfillTests")
        let store = BackfillJobStore(defaults: defaults)
        var saved = job(days: 90)
        saved.nextWindow = 7
        saved.recordsSent = 1234
        saved = saved.paused(.locked, at: now)
        store.save(saved)
        XCTAssertEqual(store.load(), saved)

        defaults.set(Data("not json".utf8), forKey: BackfillJobStore.key)
        XCTAssertNil(store.load())
        XCTAssertNil(defaults.data(forKey: BackfillJobStore.key))
    }

    func testOnlyAPauseTheUserDidNotAskForResumesByItselfForADay() {
        let base = job(days: 30)
        func resumes(_ reason: BackfillJob.PauseReason, hoursAgo: Double, webhook: Bool = true) -> Bool {
            let paused = base.paused(reason, at: now.addingTimeInterval(-hoursAgo * 3600))
            return BackfillResume.shouldAutoResume(paused, now: now, hasWebhook: webhook, hasTypes: true)
        }
        XCTAssertTrue(resumes(.background, hoursAgo: 1))
        XCTAssertTrue(resumes(.locked, hoursAgo: 23))
        XCTAssertTrue(resumes(.closed, hoursAgo: 2))
        XCTAssertTrue(resumes(.interrupted, hoursAgo: 2))
        XCTAssertFalse(resumes(.locked, hoursAgo: 25))
        XCTAssertFalse(resumes(.user, hoursAgo: 1))
        XCTAssertFalse(resumes(.system, hoursAgo: 1))
        XCTAssertFalse(resumes(.background, hoursAgo: 1, webhook: false))
        XCTAssertFalse(BackfillResume.shouldAutoResume(
            base.failed(.delivery, at: now), now: now, hasWebhook: true, hasTypes: true
        ))
    }
}
