import XCTest
@testable import LifeDashboardCompanion

/// Data resolution: Android's SeriesBucketingTest and ResolutionPayloadTest, on the iPhone's
/// payload dictionaries, plus the carry between syncs and the backfill's chunks.
final class SeriesResolutionTests: XCTestCase {

    private func at(_ text: String) -> Date {
        ISO8601DateFormatter().date(from: text)!
    }

    private func sample(_ time: String, _ value: Double, source: String? = nil, uuid: String? = nil) -> CarriedSample {
        CarriedSample(time: at(time), value: value, source: source, uuid: uuid)
    }

    private func heartRate(_ time: String, _ bpm: Int, uuid: String = UUID().uuidString, source: String = "Apple Watch") -> [String: Any] {
        ["bpm": bpm, "time": time, "uuid": uuid, "source": source]
    }

    private func steps(_ start: String, _ count: Int, uuid: String = UUID().uuidString) -> [String: Any] {
        ["count": count, "start_time": start, "end_time": start, "uuid": uuid, "source": "iPhone"]
    }

    private func buckets(_ payload: [String: Any], _ key: String = "heart_rate") -> [[String: Any]] {
        payload[key] as? [[String: Any]] ?? []
    }

    private func starts(_ payload: [String: Any], _ key: String = "heart_rate") -> [String] {
        buckets(payload, key).compactMap { $0["bucket_start"] as? String }
    }

    private func json(_ object: Any) throws -> String {
        String(bytes: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), encoding: .utf8) ?? ""
    }

    // MARK: - Bucketing

    func testRawResolutionProducesNoBuckets() {
        XCTAssertEqual(SeriesBucketing.bucket([sample("2026-09-14T08:00:10Z", 60)], resolution: .raw), [])
    }

    func testSamplesInOneWindowCollapseToOneBucket() throws {
        let bucket = try XCTUnwrap(SeriesBucketing.bucket([
            sample("2026-09-14T08:00:05Z", 60), sample("2026-09-14T08:00:35Z", 90), sample("2026-09-14T08:00:50Z", 72)
        ], resolution: .oneMinute).first)
        XCTAssertEqual(bucket.start, at("2026-09-14T08:00:00Z"))
        XCTAssertEqual(bucket.end, at("2026-09-14T08:01:00Z"))
        XCTAssertEqual(bucket.mean, 74, accuracy: 0.0001)
        XCTAssertEqual(bucket.minimum, 60)
        XCTAssertEqual(bucket.maximum, 90)
        XCTAssertEqual(bucket.total, 222)
        XCTAssertEqual(bucket.sampleCount, 3)
    }

    func testWindowsAreAlignedToTheClockAndComeBackInOrder() {
        let result = SeriesBucketing.bucket([
            sample("2026-09-14T08:52:00Z", 3), sample("2026-09-14T08:07:00Z", 1), sample("2026-09-14T08:16:00Z", 2)
        ], resolution: .fifteenMinutes)
        XCTAssertEqual(result.map(\.start), [at("2026-09-14T08:00:00Z"), at("2026-09-14T08:15:00Z"), at("2026-09-14T08:45:00Z")])
    }

    func testTotalsAndCountsArePreservedAndSourcesListedOnce() {
        let input = (0..<500).map { CarriedSample(time: at("2026-09-14T00:00:00Z").addingTimeInterval(Double($0) * 37), value: Double($0 % 7), source: $0.isMultiple(of: 2) ? "Watch" : "iPhone") }
        let result = SeriesBucketing.bucket(input, resolution: .fiveMinutes)
        XCTAssertEqual(result.map(\.total).reduce(0, +), input.map(\.value).reduce(0, +))
        XCTAssertEqual(result.map(\.sampleCount).reduce(0, +), 500)
        XCTAssertEqual(result.first?.sources, ["Watch", "iPhone"].sorted())
    }

    func testSamplesBeforeTheEpochStillAlignDownwards() {
        let result = SeriesBucketing.bucket([sample("1969-12-31T23:59:30Z", 1)], resolution: .oneMinute)
        XCTAssertEqual(result.first?.start, at("1969-12-31T23:59:00Z"))
    }

    func testABucketThatEndsExactlyAtTheBoundaryIsClosed() {
        let result = SeriesBucketing.bucket([sample("2026-09-14T08:01:00Z", 1), sample("2026-09-14T08:06:00Z", 2)], resolution: .fiveMinutes)
        let split = SeriesBucketing.splitClosed(result, boundary: at("2026-09-14T08:05:00Z"))
        XCTAssertEqual(split.closed.map(\.start), [at("2026-09-14T08:00:00Z")])
        XCTAssertEqual(split.openFrom, at("2026-09-14T08:05:00Z"))
    }

    // MARK: - Types and names

    func testMeasurementsAreAveragedAndQuantitiesSummed() {
        XCTAssertEqual(ResolutionFamily.configurableTypes, [.steps, .heartRate, .distance, .activeCalories, .totalCalories, .oxygenSaturation, .respiratoryRate, .heartRateVariability])
        XCTAssertEqual(ResolutionFamily.of(.heartRate), .sampled)
        XCTAssertEqual(ResolutionFamily.of(.steps), .accumulated)
        XCTAssertNil(ResolutionFamily.of(.sleep))
        XCTAssertNil(ResolutionFamily.of(.weight))
        for type in HealthDataType.allCases {
            XCTAssertEqual(ResolutionFamily.of(type) != nil, type.seriesFields != nil, type.rawValue)
        }
    }

    func testResolutionsAreNamedLikeAndroid() {
        XCTAssertEqual(SeriesResolution.allCases.map(\.rawValue), ["RAW", "ONE_MINUTE", "FIVE_MINUTES", "FIFTEEN_MINUTES", "HOURLY"])
        XCTAssertEqual(SeriesResolution.allCases.map(\.payloadName), ["raw", "1m", "5m", "15m", "1h"])
        XCTAssertEqual(SeriesResolution.from("TWO_HOURS"), .raw)
        XCTAssertEqual(SeriesResolution.from(nil), .raw)
        XCTAssertEqual(SeriesResolution.defaultResolution, .raw)
    }

    // MARK: - Payload shape

    func testAMeasurementBucketCarriesTheAverageAndItsRange() throws {
        let bucket = Bucket(start: at("2026-09-14T08:00:00Z"), end: at("2026-09-14T08:01:00Z"), mean: 217.0 / 3, minimum: 66, maximum: 81, total: 217, sampleCount: 3, sources: ["Apple Watch"])
        let text = try json(ResolutionPayload.bucketJSON(bucket, family: .sampled))
        XCTAssertEqual(text, #"{"avg":72.33333333333333,"bucket_end":"2026-09-14T08:01:00Z","bucket_start":"2026-09-14T08:00:00Z","max":81,"min":66,"sample_count":3,"sources":["Apple Watch"]}"#)
    }

    func testAQuantityBucketCarriesTheTotalAndNoRangeOrSourcesWhenUnknown() throws {
        let bucket = Bucket(start: at("2026-09-14T08:00:00Z"), end: at("2026-09-14T09:00:00Z"), mean: 0.1, minimum: 0.1, maximum: 0.2, total: 0.1 + 0.2, sampleCount: 2, sources: [])
        let text = try json(ResolutionPayload.bucketJSON(bucket, family: .accumulated))
        XCTAssertEqual(text, #"{"bucket_end":"2026-09-14T09:00:00Z","bucket_start":"2026-09-14T08:00:00Z","sample_count":2,"total":0.30000000000000004}"#)
    }

    // MARK: - Applying to a payload

    func testWithEveryTypeAtRawThePayloadIsUntouched() throws {
        let payload: [String: Any] = ["heart_rate": [heartRate("2026-09-14T08:00:10Z", 60, uuid: "a")], "timestamp": "x"]
        let resolved = ResolutionApplier.apply(to: payload, resolutions: [.steps: .raw], now: at("2026-09-14T12:00:00Z"))
        XCTAssertEqual(try json(resolved.payload), try json(payload))
        XCTAssertEqual(resolved.absorbedRecords, 0)
        XCTAssertNil(resolved.payload["_resolutions"])
    }

    func testABucketedSeriesReplacesItsRecordsAndNamesItsWindow() throws {
        let payload: [String: Any] = [
            "heart_rate": [heartRate("2026-09-14T08:00:10Z", 60), heartRate("2026-09-14T08:00:40Z", 80)],
            "steps": [steps("2026-09-14T08:10:00Z", 100), steps("2026-09-14T08:40:00Z", 50)],
            "weight": [["kilograms": 80.5, "time": "2026-09-14T07:00:00Z"]],
            "deleted_records": [["uuid": "gone", "type": "heart_rate"]]
        ]
        let resolved = ResolutionApplier.apply(
            to: payload, resolutions: [.heartRate: .oneMinute, .steps: .hourly], now: at("2026-09-14T12:00:00Z")
        )
        let heart = try XCTUnwrap(buckets(resolved.payload).first)
        XCTAssertNil(heart["bpm"], "An aggregate never carries the raw field name")
        XCTAssertEqual(heart["sample_count"] as? Int, 2)
        XCTAssertEqual((heart["avg"] as? NSNumber)?.doubleValue, 70)
        let step = try XCTUnwrap(buckets(resolved.payload, "steps").first)
        XCTAssertEqual((step["total"] as? NSNumber)?.doubleValue, 150)
        XCTAssertNil(step["avg"])
        XCTAssertEqual(resolved.payload["_resolutions"] as? [String: String], ["heart_rate": "1m", "steps": "1h"])
        XCTAssertEqual((resolved.payload["weight"] as? [Any])?.count, 1, "Types without a window keep their records")
        XCTAssertNotNil(resolved.payload["deleted_records"], "Deletions go out as they are")
        XCTAssertEqual(resolved.absorbedRecords, 4)
        XCTAssertEqual(resolved.bucketCount, 2)
        XCTAssertFalse(resolved.leavesNothingToSend(of: 5))
    }

    func testAWindowStillFillingIsCarriedAndTheSeriesStaysBucketed() {
        let payload: [String: Any] = ["heart_rate": [heartRate("2026-09-14T08:01:00Z", 60), heartRate("2026-09-14T08:06:00Z", 70)]]
        let resolved = ResolutionApplier.apply(to: payload, resolutions: [.heartRate: .fiveMinutes], now: at("2026-09-14T08:07:00Z"))
        XCTAssertEqual(starts(resolved.payload), ["2026-09-14T08:00:00Z"])
        XCTAssertEqual(resolved.carriedOut[.heartRate]?.map(\.value), [70])
    }

    func testEverythingHeldLeavesAnEmptyArrayAndNothingToSend() {
        let payload: [String: Any] = ["heart_rate": [heartRate("2026-09-14T08:06:00Z", 70)]]
        let resolved = ResolutionApplier.apply(to: payload, resolutions: [.heartRate: .fiveMinutes], now: at("2026-09-14T08:07:00Z"))
        XCTAssertEqual((resolved.payload["heart_rate"] as? [Any])?.count, 0, "Never the raw records the receiver asked not to get")
        XCTAssertEqual(resolved.payload["_resolutions"] as? [String: String], ["heart_rate": "5m"])
        XCTAssertTrue(resolved.leavesNothingToSend(of: 1))
    }

    func testCarriedSamplesCompleteTheWindowOnTheNextSyncAndItGoesOutOnce() throws {
        let first = ResolutionApplier.apply(
            to: ["heart_rate": [heartRate("2026-09-14T08:06:00Z", 60)]],
            resolutions: [.heartRate: .fiveMinutes], now: at("2026-09-14T08:07:00Z")
        )
        XCTAssertEqual(starts(first.payload), [])
        let second = ResolutionApplier.apply(
            to: ["heart_rate": [heartRate("2026-09-14T08:08:00Z", 80)]],
            resolutions: [.heartRate: .fiveMinutes], carriedIn: first.carriedOut, now: at("2026-09-14T08:20:00Z")
        )
        let bucket = try XCTUnwrap(buckets(second.payload).first)
        XCTAssertEqual(starts(second.payload), ["2026-09-14T08:05:00Z"])
        XCTAssertEqual(bucket["sample_count"] as? Int, 2)
        XCTAssertEqual((bucket["avg"] as? NSNumber)?.doubleValue, 70)
        XCTAssertNil(second.carriedOut[.heartRate])
    }

    func testACarriedWindowGoesOutOnceClosedEvenWithNothingNew() {
        let carried: [HealthDataType: [CarriedSample]] = [.heartRate: [sample("2026-09-14T08:06:00Z", 60)]]
        let resolved = ResolutionApplier.apply(to: ["steps": [steps("2026-09-14T08:30:00Z", 10)]], resolutions: [.heartRate: .fiveMinutes], carriedIn: carried, now: at("2026-09-14T09:00:00Z"))
        XCTAssertEqual(starts(resolved.payload), ["2026-09-14T08:05:00Z"])
        XCTAssertNil(resolved.carriedOut[.heartRate])
    }

    func testATypeWithNothingNewKeepsWhatItHolds() {
        let held = [sample("2026-09-14T08:56:00Z", 60)]
        let resolved = ResolutionApplier.apply(to: [:], resolutions: [.heartRate: .fiveMinutes], carriedIn: [.heartRate: held], now: at("2026-09-14T08:58:00Z"))
        XCTAssertEqual(resolved.carriedOut[.heartRate], held)
    }

    func testATypeSetBackToRawDropsWhatItHeldAndSendsItsRecords() {
        let resolved = ResolutionApplier.apply(
            to: ["heart_rate": [heartRate("2026-09-14T08:08:00Z", 80)]],
            resolutions: [:], carriedIn: [.heartRate: [sample("2026-09-14T08:06:00Z", 60)]], now: at("2026-09-14T09:00:00Z")
        )
        XCTAssertNil(resolved.carriedOut[.heartRate])
        XCTAssertEqual((resolved.payload["heart_rate"] as? [[String: Any]])?.first?["bpm"] as? Int, 80)
    }

    /// A catch-up read can return a sample the carry already holds; it counts once.
    func testASampleReadAgainCountsOnce() throws {
        let carried: [HealthDataType: [CarriedSample]] = [.heartRate: [sample("2026-09-14T08:06:00Z", 60, uuid: "same")]]
        let resolved = ResolutionApplier.apply(
            to: ["heart_rate": [heartRate("2026-09-14T08:06:00Z", 60, uuid: "same"), heartRate("2026-09-14T08:07:00Z", 80, uuid: "other")]],
            resolutions: [.heartRate: .fiveMinutes], carriedIn: carried, now: at("2026-09-14T09:00:00Z")
        )
        XCTAssertEqual(try XCTUnwrap(buckets(resolved.payload).first)["sample_count"] as? Int, 2)
    }

    /// A read that stopped at the cap continues from its newest measurement, so the window
    /// holding it may still grow, however long ago it closed by the clock.
    func testABoundaryBeforeNowKeepsItsWindowOpen() {
        let payload: [String: Any] = ["heart_rate": [heartRate("2026-09-14T08:01:00Z", 60), heartRate("2026-09-14T08:06:00Z", 80)]]
        let newest = ResolutionApplier.newestMeasurement(of: .heartRate, in: payload)
        XCTAssertEqual(newest, at("2026-09-14T08:06:00Z"))
        let resolved = ResolutionApplier.apply(
            to: payload, resolutions: [.heartRate: .fiveMinutes], now: at("2026-09-14T12:00:00Z"), boundaries: [.heartRate: newest!]
        )
        XCTAssertEqual(starts(resolved.payload), ["2026-09-14T08:00:00Z"])
        XCTAssertEqual(resolved.carriedOut[.heartRate]?.count, 1)
    }

    func testAlignUpFindsTheNextBucketBound() {
        XCTAssertEqual(SeriesBucketing.alignUp(at("2026-09-14T08:00:00Z"), resolution: .fifteenMinutes), at("2026-09-14T08:00:00Z"))
        XCTAssertEqual(SeriesBucketing.alignUp(at("2026-09-14T08:00:01Z"), resolution: .fifteenMinutes), at("2026-09-14T08:15:00Z"))
        XCTAssertEqual(SeriesBucketing.alignUp(at("2026-09-14T08:59:59Z"), resolution: .hourly), at("2026-09-14T09:00:00Z"))
        XCTAssertEqual(SeriesBucketing.alignUp(at("2026-09-14T08:00:01Z"), resolution: .raw), at("2026-09-14T08:00:01Z"))
    }

    func testACollectingPassSendsNothingAndKeepsEverything() {
        let resolved = ResolutionApplier.apply(
            to: ["heart_rate": [heartRate("2026-09-14T08:01:00Z", 60), heartRate("2026-09-14T08:06:00Z", 70)]],
            resolutions: [.heartRate: .fiveMinutes],
            carriedIn: [.heartRate: [sample("2026-09-14T07:59:00Z", 55)]],
            now: at("2026-09-14T09:00:00Z"),
            emit: false
        )
        XCTAssertNil(resolved.payload["heart_rate"])
        XCTAssertNil(resolved.payload["_resolutions"])
        XCTAssertEqual(resolved.absorbedRecords, 2)
        XCTAssertEqual(resolved.carriedOut[.heartRate]?.count, 3)
    }

    func testEveryConfigurableTypeReadsItsOwnFields() {
        let records: [HealthDataType: [String: Any]] = [
            .heartRate: ["bpm": 61, "time": "2026-09-14T08:00:00Z"],
            .heartRateVariability: ["heart_rate_variability_millis": 41.5, "time": "2026-09-14T08:00:00Z"],
            .oxygenSaturation: ["percentage": 97.0, "time": "2026-09-14T08:00:00Z"],
            .respiratoryRate: ["rate": 14.5, "time": "2026-09-14T08:00:00Z"],
            .steps: ["count": 12, "start_time": "2026-09-14T08:00:00Z", "end_time": "2026-09-14T08:01:00Z"],
            .distance: ["meters": 8.25, "start_time": "2026-09-14T08:00:00Z", "end_time": "2026-09-14T08:01:00Z"],
            .activeCalories: ["calories": 1.5, "start_time": "2026-09-14T08:00:00.250Z", "end_time": "2026-09-14T08:01:00Z"],
            .totalCalories: ["calories": 2.5, "start_time": "2026-09-14T08:00:00Z", "end_time": "2026-09-14T08:01:00Z"]
        ]
        let payload = Dictionary(uniqueKeysWithValues: records.map { ($0.key.countedPayloadKey, [$0.value] as Any) })
        let resolutions = Dictionary(uniqueKeysWithValues: ResolutionFamily.configurableTypes.map { ($0, SeriesResolution.hourly) })
        let resolved = ResolutionApplier.apply(to: payload, resolutions: resolutions, now: at("2026-09-14T12:00:00Z"))
        for type in ResolutionFamily.configurableTypes {
            XCTAssertEqual(buckets(resolved.payload, type.countedPayloadKey).first?["sample_count"] as? Int, 1, type.rawValue)
        }
        XCTAssertEqual(resolved.bucketCount, 8)
    }

    /// Two syncs a few minutes apart over a dense hour: every sample in exactly one bucket,
    /// every window once.
    func testRepeatedSyncsSendEachWindowOnceWithEverySample() {
        let start = at("2026-09-14T08:00:00Z")
        let all = (0..<720).map { heartRate(start.addingTimeInterval(Double($0) * 5).iso8601String, 60 + $0 % 30, uuid: "s\($0)") }
        var carry: [HealthDataType: [CarriedSample]] = [:]
        var sent: [String] = []
        var counted = 0
        for cut in stride(from: 0, to: 720, by: 97) {
            let syncAt = start.addingTimeInterval(Double(min(cut + 97, 720)) * 5)
            let resolved = ResolutionApplier.apply(
                to: ["heart_rate": Array(all[cut..<min(cut + 97, 720)])],
                resolutions: [.heartRate: .fiveMinutes], carriedIn: carry, now: syncAt
            )
            carry = resolved.carriedOut
            sent += starts(resolved.payload)
            counted += buckets(resolved.payload).compactMap { $0["sample_count"] as? Int }.reduce(0, +)
        }
        let last = ResolutionApplier.apply(to: [:], resolutions: [.heartRate: .fiveMinutes], carriedIn: carry, now: at("2026-09-14T10:00:00Z"))
        sent += starts(last.payload)
        counted += buckets(last.payload).compactMap { $0["sample_count"] as? Int }.reduce(0, +)
        XCTAssertEqual(sent.count, 12)
        XCTAssertEqual(Set(sent).count, 12)
        XCTAssertEqual(counted, 720)
    }

    // MARK: - Carry store

    func testTheCarrySurvivesTheStoreAndAnEmptyOneRemovesTheFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("carry-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = BucketCarryStore(directory: directory)
        XCTAssertEqual(store.load(), [:])
        let carry: [HealthDataType: [CarriedSample]] = [.heartRate: [sample("2026-09-14T08:06:00Z", 60.5, source: "Watch", uuid: "a")], .steps: []]
        store.save(carry)
        XCTAssertEqual(store.load(), [.heartRate: carry[.heartRate]!])
        store.save([:])
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("carry.json").path))
        XCTAssertEqual(store.load(), [:])
    }

    func testAnAnchorCommitSavesTheCarryOnlyWhenItHoldsOne() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("carry-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = BucketCarryStore(directory: directory)
        let held: [HealthDataType: [CarriedSample]] = [.heartRate: [sample("2026-09-14T08:06:00Z", 60)]]
        store.save(held)
        let suite = "carry-commit-\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        let prefs = PreferencesManager(defaults: UserDefaults(suiteName: suite)!, secrets: InMemorySecretStore())

        AnchorCommit().save(to: prefs, carryStore: store)
        XCTAssertEqual(store.load(), held, "A commit without a carry leaves the stored one alone")
        var commit = AnchorCommit()
        commit.bucketCarry = [:]
        commit.save(to: prefs, carryStore: store)
        XCTAssertEqual(store.load(), [:])
    }

    // MARK: - Backfill

    func testABucketedTypeIsReadFromBucketBoundToBucketBound() {
        let window = DateInterval(start: at("2026-09-14T08:07:30Z"), end: at("2026-09-17T08:07:30Z"))
        let rangeEnd = at("2026-09-20T08:07:30Z")
        XCTAssertEqual(BackfillPlan.readWindow(for: window, rangeEnd: rangeEnd, resolution: nil), window)
        XCTAssertEqual(BackfillPlan.readWindow(for: window, rangeEnd: rangeEnd, resolution: .raw), window)
        XCTAssertEqual(
            BackfillPlan.readWindow(for: window, rangeEnd: rangeEnd, resolution: .fifteenMinutes),
            DateInterval(start: at("2026-09-14T08:15:00Z"), end: at("2026-09-17T08:15:00Z"))
        )
        XCTAssertEqual(
            BackfillPlan.readWindow(for: window, rangeEnd: window.end, resolution: .fifteenMinutes).end, window.end,
            "The last window stops at the end of the range"
        )
    }

    func testABackfillSendsEachBucketOnceWholeAcrossChunksAndWindows() async throws {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000.75)
        let range = BackfillPlan.range(days: 6, now: now)
        // A heart rate sample every 30 seconds: 17,280 over the two windows, many chunks each.
        let times = stride(from: range.start.timeIntervalSince1970.rounded(.up), to: range.end.timeIntervalSince1970, by: 30)
            .map { Date(timeIntervalSince1970: $0) }
        let reader = HeartRateReader(times: times)
        let sink = CollectingSink()
        let engine = BackfillEngine(
            reader: reader,
            sink: sink,
            appVersion: "9.9.9",
            enabledTypes: { [.heartRate] },
            resolutions: { [.heartRate: .fiveMinutes] },
            now: { now }
        )
        let job = await engine.run(BackfillJob(days: 6, range: range, now: now))
        XCTAssertEqual(job.status, .done)

        let payloads = await sink.payloads()
        XCTAssertGreaterThan(payloads.count, 2)
        var sent: [String] = []
        var counted = 0
        for payload in payloads {
            XCTAssertNil((payload["heart_rate"] as? [[String: Any]])?.first?["bpm"])
            XCTAssertEqual(payload["_resolutions"] as? [String: String], ["heart_rate": "5m"])
            let windowStart = try XCTUnwrap(ISO8601DateFormatter().date(from: payload["window_start"] as? String ?? ""))
            for bucket in buckets(payload) {
                let start = try XCTUnwrap(ISO8601DateFormatter().date(from: bucket["bucket_start"] as? String ?? ""))
                XCTAssertGreaterThanOrEqual(start, windowStart, "A bucket goes with the backfill window it starts in")
                sent.append(bucket["bucket_start"] as? String ?? "")
                counted += bucket["sample_count"] as? Int ?? 0
            }
        }
        // Every bucket wholly inside the range, once, with all its samples; the ones cut by the
        // start and the end of the range are left out.
        let first = SeriesBucketing.alignUp(range.start, resolution: .fiveMinutes)
        let last = Date(timeIntervalSince1970: (range.end.timeIntervalSince1970 / 300).rounded(.down) * 300)
        let inside = times.filter { $0 >= first && $0 < last }
        XCTAssertEqual(sent.count, Set(sent).count, "A bucket went out twice")
        XCTAssertEqual(sent.count, Int(last.timeIntervalSince(first) / 300))
        XCTAssertEqual(counted, inside.count)
    }
}

private actor HeartRateReader: BackfillReading {
    let times: [Date]

    init(times: [Date]) {
        self.times = times
    }

    func canRead() async -> Bool { true }

    func readSlice(_ type: HealthDataType, from cursor: Date, window: DateInterval, rangeEnd: Date) async throws -> BackfillSlice {
        let limit = SyncLimits.maxRecordsPerSync(for: type)
        let inRange = times.filter { $0 >= cursor && $0 < window.end }
        let slice = SyncLimits.sliceEnd(probedStartDates: Array(inRange.prefix(limit)), limit: limit, from: cursor, to: window.end)
        let records: [[String: Any]] = inRange.filter { $0 < slice.end }.map {
            ["bpm": 70, "time": $0.iso8601String, "uuid": "hr-\($0.timeIntervalSince1970)", "source": "Apple Watch"]
        }
        return BackfillSlice(records: records.isEmpty ? [] : [("heart_rate", records)], end: slice.end, exact: slice.exact)
    }
}

private actor CollectingSink: BackfillDelivering {
    private var sent: [Data] = []

    func deliver(_ body: Data, recordCount: Int) async -> Bool {
        sent.append(body)
        return true
    }

    func payloads() -> [[String: Any]] {
        sent.map { (try? JSONSerialization.jsonObject(with: $0) as? [String: Any]) ?? [:] }
    }
}
