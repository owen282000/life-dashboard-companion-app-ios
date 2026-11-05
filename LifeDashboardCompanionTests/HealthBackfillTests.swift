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

private actor ReportedTypes {
    private(set) var types: [[HealthDataType]] = []
    func add(_ value: [HealthDataType]) { types.append(value) }
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
        var engine = BackfillEngine(
            reader: reader,
            sink: sink,
            appVersion: "9.9.9",
            enabledTypes: { types },
            shouldStop: { stop },
            now: { fixed }
        )
        let counter = sequence
        engine.sequence = { counter.next() }
        engine.pause = { _ in }
        return engine
    }

    /// A counter of the test's own, so the app's is left alone.
    private lazy var sequence: PayloadSequence = {
        let suite = "backfill-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        self.addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return PayloadSequence(defaults: defaults)
    }()

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
            sequence: 42,
            now: now
        ))
        let text = try XCTUnwrap(String(data: body, encoding: .utf8))
        XCTAssertTrue(text.contains("\"backfill\":true"))
        XCTAssertTrue(text.contains("\"window_complete\":false"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["timezone"] as? String, TimeZone.current.identifier, "the zone daily_totals cut their days in")
        XCTAssertEqual(json["window_start"] as? String, "2023-11-14T22:13:20Z")
        XCTAssertEqual(json["window_end"] as? String, "2023-11-17T22:13:20Z")
        XCTAssertEqual(json["source"] as? String, "healthkit_ios")
        XCTAssertNotNil(json["daily_totals"])
        XCTAssertNotNil(json["steps"])
        XCTAssertEqual(json["sequence"] as? Int, 42, "the syncs' counter, as on Android")
        for key in ["deleted_records", "deletions_unavailable", "writeback", "_diagnostics"] {
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
        XCTAssertEqual(bodies.map { $0["sequence"] as? Int }, [1, 2, 3], "one number per payload, in the order they go")
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

    // MARK: - Records and totals that disagree

    /// The day after the window's first midnight: a whole day inside a three-day window.
    private func dayInside(_ window: DateInterval) -> String {
        let calendar = DailyTotals.calendar()
        let day = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: window.start))!
        return DailyTotals.dateString(day, calendar: calendar)
    }

    private func totals(_ entries: [[String: Any]]) -> BackfillExtras {
        BackfillExtras(fields: entries.isEmpty ? [:] : ["daily_totals": entries], expectsTotals: true)
    }

    func testAWindowWhoseRecordsAndTotalsDisagreeIsReadAgain() async {
        let reader = FakeReader()
        let sink = FakeSink()
        let calls = Counter()
        let start = job(days: 3)
        let window = BackfillPlan.window(0, of: start.range)
        await reader.add(.steps, count: 5, from: start.rangeStart, every: 3600, prefix: "s")
        let day = dayInside(window)
        let incomplete = Counter()
        var engine = engine(reader, sink, types: [.steps])
        engine.onIncomplete = { _, _ in await incomplete.increment() }
        // Apple Health leaves the steps out of the first answer and gives them on the second.
        engine.windowExtras = { _ in
            await calls.increment()
            let first = await calls.value == 1
            return self.totals(first ? [["date": day, "active_calories": 10]] : [["date": day, "steps": 5]])
        }

        let final = await engine.run(start)

        XCTAssertEqual(final.status, .done)
        let asked = await calls.value
        XCTAssertEqual(asked, 2)
        let bodies = decoded(await sink.sent)
        XCTAssertEqual(bodies.count, 2, "the window goes out again in full")
        XCTAssertEqual((bodies.last?["daily_totals"] as? [[String: Any]])?.first?["steps"] as? Int, 5)
        XCTAssertEqual(final.recordsSent, 5, "a window read again counts its records once")
        let warned = await incomplete.value
        XCTAssertEqual(warned, 0)
    }

    func testAWindowThatStaysIncompleteGoesOutAfterThreeReadsAndIsReported() async {
        let reader = FakeReader()
        let sink = FakeSink()
        let calls = Counter()
        let start = job(days: 6)
        await reader.add(.steps, count: 5, from: start.rangeStart, every: 3600, prefix: "s")
        let reported = ReportedTypes()
        var engine = engine(reader, sink, types: [.steps])
        engine.onIncomplete = { _, types in await reported.add(types) }
        engine.windowExtras = { _ in
            await calls.increment()
            return self.totals([])
        }

        let final = await engine.run(start)

        XCTAssertEqual(final.status, .done)
        XCTAssertEqual(final.nextWindow, 2, "the run goes on")
        let asked = await calls.value
        XCTAssertEqual(asked, BackfillCheck.maxAttempts + 1, "three reads of the first window, one of the empty second")
        let types = await reported.types
        XCTAssertEqual(types, [[.steps]])
    }

    func testAWindowWhoseRecordsAndTotalsAgreeIsReadOnce() async {
        let reader = FakeReader()
        let sink = FakeSink()
        let calls = Counter()
        let start = job(days: 3)
        let day = dayInside(BackfillPlan.window(0, of: start.range))
        await reader.add(.steps, count: 5, from: start.rangeStart, every: 3600, prefix: "s")
        var engine = engine(reader, sink, types: [.steps, .distance])
        engine.windowExtras = { _ in
            await calls.increment()
            return self.totals([["date": day, "steps": 5]])
        }
        _ = await engine.run(start)
        let asked = await calls.value
        XCTAssertEqual(asked, 1, "no distance at all is no data, not a disagreement")
    }

    func testTheCheckComparesEachTypeWithItsOwnTotal() {
        let calendar = DailyTotals.calendar()
        let window = BackfillPlan.window(0, of: job(days: 3).range)
        let day = dayInside(window)
        let edge = DailyTotals.dateString(window.start, calendar: calendar)
        let extras = totals([["date": day, "distance_meters": 800.0], ["date": edge, "active_calories": 20.0]])

        XCTAssertEqual(
            BackfillCheck.disagreeing(rawCounts: [.distance: 0], extras: extras, window: window, calendar: calendar),
            [.distance], "a total on a day inside the window without any record"
        )
        XCTAssertEqual(
            BackfillCheck.disagreeing(rawCounts: [.activeCalories: 0], extras: extras, window: window, calendar: calendar),
            [], "the window starts inside that day, so its records can be before the window"
        )
        XCTAssertEqual(
            BackfillCheck.disagreeing(rawCounts: [.totalCalories: 40], extras: extras, window: window, calendar: calendar),
            [], "total calories also need resting energy, so they are not compared"
        )
        XCTAssertEqual(
            BackfillCheck.disagreeing(rawCounts: [.steps: 3], extras: .none, window: window, calendar: calendar),
            [], "no totals asked for, nothing to compare"
        )
    }

    @MainActor
    func testARunWritesOneRowPerWebhookSoEachShowsTheBackfill() {
        var done = job(days: 3)
        done.status = .done
        let rows = BackfillController.runRows(
            urls: ["https://a.example/hook", "https://b.example/hook", "http://c.local:8123/hook"],
            missed: ["https://b.example/hook"],
            final: done,
            sent: 120,
            rawPayload: nil
        )
        XCTAssertEqual(rows.map(\.url), ["https://a.example/hook", "https://b.example/hook", "http://c.local:8123/hook"])
        XCTAssertEqual(rows.map(\.success), [true, false, true], "the one that missed chunks is not a success")
        XCTAssertEqual(rows[1].errorMessage, AppDiagnostic.backfillMissed)
        XCTAssertTrue(rows.allSatisfy { $0.dataType == WebhookLog.backfillRunDataType && $0.recordCount == 120 })
        XCTAssertEqual(rows[1].syncKind, .other, "its failed chunks already count as failed deliveries")
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

    // MARK: - All history (P2-29)

    private let october = Date(timeIntervalSince1970: 1_792_000_000.4)  // October 2026, with a fraction

    func testAllHistoryStartsAtTheOldestRecordFlooredToASecond() {
        let oldest = Date(timeIntervalSince1970: 1_500_000_000.7)
        let range = BackfillPlan.range(days: BackfillPlan.allHistory, now: october, earliest: oldest)
        XCTAssertEqual(range.start, Date(timeIntervalSince1970: 1_500_000_000))
        XCTAssertEqual(range.end, Date(timeIntervalSince1970: 1_792_000_000))
    }

    func testAllHistoryIgnoresAnythingBefore2000() {
        let range = BackfillPlan.range(days: BackfillPlan.allHistory, now: october, earliest: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(range.start, BackfillPlan.allHistoryNotBefore)
    }

    func testAllHistoryCoversADayAtLeast() {
        let range = BackfillPlan.range(days: BackfillPlan.allHistory, now: october, earliest: october.addingTimeInterval(-60))
        XCTAssertEqual(range.duration, 86_400)
        XCTAssertEqual(BackfillPlan.windowCount(of: range), 1)
    }

    func testAllHistoryStaysWithinWhatHealthKitPermits() {
        let permitted = october.addingTimeInterval(-400 * 86_400)
        let range = BackfillPlan.range(days: BackfillPlan.allHistory, now: october, earliestPermitted: permitted,
                                       earliest: Date(timeIntervalSince1970: 1_000_000_000))
        XCTAssertEqual(range.start, permitted)
    }

    func testTheListLeavesOutLengthsPastTheOldestRecord() {
        XCTAssertEqual(BackfillPlan.lengths(earliest: nil, now: october), [30, 90, 180, 365, 730, 1825, 0])
        // A record 400 days back: 1 year fits, 2 and 5 years would send what All history sends.
        XCTAssertEqual(BackfillPlan.lengths(earliest: october.addingTimeInterval(-400 * 86_400), now: october), [30, 90, 180, 365, 0])
        // Exactly 365 days back: a year would reach the oldest record, so it goes too.
        XCTAssertEqual(BackfillPlan.lengths(earliest: october.addingTimeInterval(-365 * 86_400), now: october), [30, 90, 180, 0])
        XCTAssertEqual(BackfillPlan.lengths(earliest: october.addingTimeInterval(-10 * 86_400), now: october), [0])
    }

    func testTheChunksPerLengthAreThreeDayWindowsRoundedUp() {
        XCTAssertEqual(BackfillPlan.lengths.dropLast().map(BackfillPlan.windows(days:)), [10, 30, 60, 122, 244, 609])
        XCTAssertEqual(BackfillPlan.windows(days: 1825),
                       BackfillPlan.windowCount(of: BackfillPlan.range(days: 1825, now: october)))
    }
}
