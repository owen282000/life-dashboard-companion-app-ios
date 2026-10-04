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
        let newest = ResolutionApplier.newestMeasurement(of: .heartRate, in: payload, notAfter: at("2026-09-14T12:00:00Z"))
        XCTAssertEqual(newest, at("2026-09-14T08:06:00Z"))
        let resolved = ResolutionApplier.apply(
            to: payload, resolutions: [.heartRate: .fiveMinutes], now: at("2026-09-14T12:00:00Z"), boundaries: [.heartRate: newest!]
        )
        XCTAssertEqual(starts(resolved.payload), ["2026-09-14T08:00:00Z"])
        XCTAssertEqual(resolved.carriedOut[.heartRate]?.count, 1)
    }

    func testAFutureSampleDoesNotMoveTheBoundary() {
        let carried = [sample("2026-09-15T08:00:00Z", 60)]
        let payload: [String: Any] = ["heart_rate": [heartRate("2026-09-14T08:06:00Z", 80)]]
        XCTAssertEqual(
            ResolutionApplier.newestMeasurement(of: .heartRate, in: payload, carried: carried, notAfter: at("2026-09-14T12:00:00Z")),
            at("2026-09-14T08:06:00Z")
        )
    }

    /// A type the sync did not read this round holds what it has: samples behind its anchor may
    /// still belong to its windows.
    func testABoundaryInThePastHoldsEverything() {
        let carried: [HealthDataType: [CarriedSample]] = [.heartRate: [sample("2026-09-14T08:06:00Z", 60)]]
        let resolved = ResolutionApplier.apply(
            to: [:], resolutions: [.heartRate: .fiveMinutes], carriedIn: carried, now: at("2026-09-14T12:00:00Z"),
            boundaries: [.heartRate: .distantPast]
        )
        XCTAssertEqual(starts(resolved.payload), [])
        XCTAssertEqual(resolved.carriedOut, carried)
    }

    /// Android drops what a type held when it goes back to raw; here it goes out as the records
    /// it was read from.
    func testATypeSetBackToRawSendsWhatItHeldAsRecords() throws {
        let carried: [HealthDataType: [CarriedSample]] = [
            .heartRate: [sample("2026-09-14T08:06:00Z", 61, source: "Watch", uuid: "held"), sample("2026-09-14T08:07:00Z", 70, uuid: "again")],
            .steps: [CarriedSample(time: at("2026-09-14T08:10:00Z"), value: 42, source: "iPhone", uuid: "s", end: at("2026-09-14T08:11:00Z"))]
        ]
        let resolved = ResolutionApplier.apply(
            to: ["heart_rate": [heartRate("2026-09-14T08:07:00Z", 70, uuid: "again")]],
            resolutions: [:], carriedIn: carried, now: at("2026-09-14T09:00:00Z")
        )
        let heart = resolved.payload["heart_rate"] as? [[String: Any]] ?? []
        XCTAssertEqual(heart.compactMap { $0["uuid"] as? String }.sorted(), ["again", "held"], "A sample read again is not sent twice")
        let held = try XCTUnwrap(heart.first { $0["uuid"] as? String == "held" })
        XCTAssertEqual(held["bpm"] as? Int, 61)
        XCTAssertEqual(held["time"] as? String, "2026-09-14T08:06:00Z")
        XCTAssertEqual(held["source"] as? String, "Watch")
        let step = try XCTUnwrap((resolved.payload["steps"] as? [[String: Any]])?.first)
        XCTAssertEqual(step["count"] as? Int, 42)
        XCTAssertEqual(step["start_time"] as? String, "2026-09-14T08:10:00Z")
        XCTAssertEqual(step["end_time"] as? String, "2026-09-14T08:11:00Z")
        XCTAssertEqual(resolved.carriedOut, [:])
        XCTAssertEqual(resolved.restoredRecords, 2)
        XCTAssertNil(resolved.payload["_resolutions"])
    }

    /// Only the resolutions can leave a payload with nothing to send; one that holds records
    /// the count does not see is posted as before.
    func testWithoutBucketingThereIsAlwaysSomethingToSend() {
        let resolved = ResolutionApplier.apply(to: ["menstruation_period": [["start_time": "x"]]], resolutions: [:], now: Date())
        XCTAssertFalse(resolved.leavesNothingToSend(of: 0))
    }

    /// Total, min and max keep the decimals of the records' field, the average its shortest
    /// form, and all of it goes through PayloadJSON as it is.
    func testBucketNumbersKeepTheirFieldsDecimalsThroughPayloadJSON() throws {
        let resolved = ResolutionApplier.apply(
            to: ["active_calories": [["calories": 0.1, "start_time": "2026-09-14T08:00:00Z"], ["calories": 0.2, "start_time": "2026-09-14T08:01:00Z"]],
                 "oxygen_saturation": [["percentage": 97.25, "time": "2026-09-14T08:00:00Z"], ["percentage": 96.0, "time": "2026-09-14T08:01:00Z"]]],
            resolutions: [.activeCalories: .hourly, .oxygenSaturation: .hourly], now: at("2026-09-14T12:00:00Z")
        )
        let text = String(bytes: try XCTUnwrap(PayloadJSON.data(resolved.payload)), encoding: .utf8) ?? ""
        XCTAssertTrue(text.contains(#""total":0.3"#), text)
        XCTAssertTrue(text.contains(#""avg":96.625"#), text)
        XCTAssertTrue(text.contains(#""max":97.3"#), text)
        XCTAssertTrue(text.contains(#""min":96"#), text)
    }

    func testANumberBeyondADecimalStaysADouble() throws {
        XCTAssertEqual(ResolutionPayload.number(1e200).doubleValue, 1e200)
        XCTAssertEqual(ResolutionPayload.number(5e-324).doubleValue, 0, "Below a decimal's range, as PayloadJSON writes it")
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: ["v": ResolutionPayload.number(1e200), "w": ResolutionPayload.number(.nan)]))
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

    /// The carry and the anchors move together: a carry that cannot be written keeps the
    /// cursors and anchors where they were, so its samples are read again, not lost.
    func testACarryThatCannotBeWrittenKeepsTheCursors() throws {
        let blocked = FileManager.default.temporaryDirectory.appendingPathComponent("carry-blocked-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: blocked) }
        try Data("not a directory".utf8).write(to: blocked)
        let store = BucketCarryStore(directory: blocked)
        let suite = "carry-blocked-\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        let prefs = PreferencesManager(defaults: UserDefaults(suiteName: suite)!, secrets: InMemorySecretStore())

        var commit = AnchorCommit()
        commit.cursors = [(.heartRate, at("2026-09-14T08:00:00Z"))]
        commit.bucketCarry = [.heartRate: [sample("2026-09-14T08:06:00Z", 60)]]
        commit.save(to: prefs, carryStore: store)
        XCTAssertNil(prefs.loadCatchUpCursor(for: .heartRate))

        commit.save(to: prefs, carryStore: BucketCarryStore(directory: blocked.appendingPathExtension("ok")))
        addTeardownBlock { try? FileManager.default.removeItem(at: blocked.appendingPathExtension("ok")) }
        XCTAssertEqual(prefs.loadCatchUpCursor(for: .heartRate), at("2026-09-14T08:00:00Z"))
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

    /// More samples at one instant than a read holds: the pass after them reads nothing, ends
    /// the type and closes the bucket they are in, which must still be posted.
    func testABackfillPassThatOnlyClosesABucketIsSent() async throws {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000.75)
        let range = BackfillPlan.range(days: 3, now: now)
        let instant = SeriesBucketing.alignUp(range.start, resolution: .fiveMinutes).addingTimeInterval(3600 + 10)
        let reader = HeartRateReader(times: Array(repeating: instant, count: 1200))
        let sink = CollectingSink()
        let engine = BackfillEngine(
            reader: reader, sink: sink, appVersion: "9.9.9",
            enabledTypes: { [.heartRate] }, resolutions: { [.heartRate: .fiveMinutes] }, now: { now }
        )
        _ = await engine.run(BackfillJob(days: 3, range: range, now: now))
        let counts = await sink.payloads().flatMap { buckets($0) }.compactMap { $0["sample_count"] as? Int }
        XCTAssertEqual(counts, [1200])
    }
}

// MARK: - Whole windows (P2-16)

/// A window that goes out again is built from everything HealthKit holds in it and marked
/// complete, so a receiver replaces what it holds instead of adding to it: a source that
/// deletes samples and saves them again would otherwise be counted twice.
extension SeriesResolutionTests {

    private func hourOfSteps(_ count: Int = 60, each value: Double = 10) -> [CarriedSample] {
        (0..<count).map { sample(String(format: "2026-09-14T08:%02d:00Z", $0), value, source: "Watch", uuid: "s\($0)") }
    }

    private func sendSteps(_ records: [[String: Any]], whole: WholeContent?, carried: [CarriedSample] = []) -> [[String: Any]] {
        let resolved = ResolutionApplier.apply(
            to: ["steps": records],
            resolutions: [.steps: .hourly],
            carriedIn: carried.isEmpty ? [:] : [.steps: carried],
            now: at("2026-09-14T12:00:00Z"),
            whole: whole.map { [.steps: $0] } ?? [:]
        )
        return buckets(resolved.payload, "steps")
    }

    func testAWindowGoingOutAgainIsBuiltWholeAndMarkedComplete() throws {
        let late = (0..<10).map { steps(String(format: "2026-09-14T08:%02d:00Z", $0), 10) }
        let whole = WholeContent(samples: hourOfSteps(), from: at("2026-09-14T08:00:00Z"), to: at("2026-09-14T12:00:00Z"))
        let bucket = try XCTUnwrap(sendSteps(late, whole: whole).first)
        XCTAssertEqual((bucket["total"] as? NSNumber)?.doubleValue, 600)
        XCTAssertEqual(bucket["sample_count"] as? Int, 60)
        XCTAssertEqual(bucket["complete"] as? Bool, true)
    }

    func testAWindowTheWholeReadDoesNotHoldGoesOutUnmarked() throws {
        let late = (0..<10).map { steps(String(format: "2026-09-14T08:%02d:00Z", $0), 10) }
        let partial = WholeContent(samples: Array(hourOfSteps().dropFirst(30)), from: at("2026-09-14T08:30:00Z"), to: at("2026-09-14T12:00:00Z"))
        let bucket = try XCTUnwrap(sendSteps(late, whole: partial).first)
        XCTAssertEqual((bucket["total"] as? NSNumber)?.doubleValue, 100)
        XCTAssertNil(bucket["complete"])
    }

    func testWithoutAWholeReadEveryBucketIsUnmarked() throws {
        let bucket = try XCTUnwrap(sendSteps([steps("2026-09-14T08:05:00Z", 10)], whole: nil).first)
        XCTAssertNil(bucket["complete"])
    }

    func testAHeldWindowWhoseSamplesWereAllDeletedIsNotSent() {
        let whole = WholeContent(samples: [], from: at("2026-09-14T08:00:00Z"), to: at("2026-09-14T12:00:00Z"))
        XCTAssertTrue(sendSteps([], whole: whole, carried: Array(hourOfSteps().prefix(30))).isEmpty)
    }

    func testWindowSpansReachFromTheFirstWindowToTheLastOnly() {
        let payload: [String: Any] = [
            "steps": [
                ["bucket_start": "2026-09-14T09:00:00Z", "bucket_end": "2026-09-14T10:00:00Z", "sample_count": 1, "total": 5],
                ["bucket_start": "2026-09-14T08:00:00Z", "bucket_end": "2026-09-14T09:00:00Z", "sample_count": 1, "total": 5]
            ],
            "heart_rate": [heartRate("2026-09-14T08:00:00Z", 60)]
        ]
        let spans = ResolutionApplier.windowSpans(in: payload)
        XCTAssertEqual(spans.keys.map(\.rawValue), [HealthDataType.steps.rawValue])
        XCTAssertEqual(spans[.steps], DateInterval(start: at("2026-09-14T08:00:00Z"), end: at("2026-09-14T10:00:00Z")))
    }

    func testOnlyACompleteBucketSaysSoInThePayload() {
        var bucket = Bucket(start: at("2026-09-14T08:00:00Z"), end: at("2026-09-14T09:00:00Z"), mean: 10, minimum: 10, maximum: 10, total: 600, sampleCount: 60, sources: [])
        XCTAssertNil(ResolutionPayload.bucketJSON(bucket, family: .accumulated)["complete"])
        bucket.complete = true
        XCTAssertEqual(ResolutionPayload.bucketJSON(bucket, family: .accumulated)["complete"] as? Bool, true)
    }

    /// A backfill reads a bucketed type from bucket bound to bucket bound in time order, so
    /// every bucket of steps it sends holds all its samples and is marked complete.
    func testEveryStepsBucketABackfillSendsIsComplete() async throws {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000.75)
        let range = BackfillPlan.range(days: 3, now: now)
        let first = SeriesBucketing.alignUp(range.start, resolution: .hourly)
        let times = (0..<3000).map { first.addingTimeInterval(Double($0) * 60) }
        let sink = WholeSink()
        let engine = BackfillEngine(
            reader: WholeReader(times: times, key: "steps"), sink: sink, appVersion: "9.9.9",
            enabledTypes: { [.steps] }, resolutions: { [.steps: .hourly] }, now: { now }
        )
        _ = await engine.run(BackfillJob(days: 3, range: range, now: now))
        let sent = await sink.payloads().flatMap { buckets($0, "steps") }
        XCTAssertFalse(sent.isEmpty)
        XCTAssertTrue(sent.allSatisfy { $0["complete"] as? Bool == true }, "\(sent.filter { $0["complete"] == nil })")
        XCTAssertEqual(sent.compactMap { ($0["total"] as? NSNumber)?.intValue }.reduce(0, +), sent.compactMap { $0["sample_count"] as? Int }.reduce(0, +) * 10)
    }

    /// A measured series goes out as before: combining a sample that came again leaves its
    /// average, minimum and maximum alone, so no bucket of it is marked.
    func testABackfillNeverMarksAMeasuredSeries() async throws {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000.75)
        let range = BackfillPlan.range(days: 3, now: now)
        let first = SeriesBucketing.alignUp(range.start, resolution: .fiveMinutes)
        let times = (0..<3000).map { first.addingTimeInterval(Double($0) * 20) }
        let sink = WholeSink()
        let engine = BackfillEngine(
            reader: WholeReader(times: times, key: "heart_rate"), sink: sink, appVersion: "9.9.9",
            enabledTypes: { [.heartRate] }, resolutions: { [.heartRate: .fiveMinutes] }, now: { now }
        )
        _ = await engine.run(BackfillJob(days: 3, range: range, now: now))
        let sent = await sink.payloads().flatMap { buckets($0) }
        XCTAssertFalse(sent.isEmpty)
        XCTAssertTrue(sent.allSatisfy { $0["complete"] == nil })
    }

    /// More steps at one instant than one read holds: the window cannot be read in full, so its
    /// bucket goes out unmarked.
    func testABackfillBucketThatCouldNotBeReadInFullIsNotMarked() async throws {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000.75)
        let range = BackfillPlan.range(days: 3, now: now)
        let instant = SeriesBucketing.alignUp(range.start, resolution: .hourly).addingTimeInterval(3600 + 10)
        let sink = WholeSink()
        let engine = BackfillEngine(
            reader: WholeReader(times: Array(repeating: instant, count: 1200), key: "steps"), sink: sink, appVersion: "9.9.9",
            enabledTypes: { [.steps] }, resolutions: { [.steps: .hourly] }, now: { now }
        )
        _ = await engine.run(BackfillJob(days: 3, range: range, now: now))
        let sent = await sink.payloads().flatMap { buckets($0, "steps") }
        XCTAssertEqual(sent.count, 1)
        XCTAssertNil(sent.first?["complete"])
    }
}

/// The test file's readers and sinks are private to it; these are the same, for the extension.
private actor WholeReader: BackfillReading {
    let times: [Date]
    /// "heart_rate" or "steps": the records the reader returns.
    let key: String

    init(times: [Date], key: String) {
        self.times = times
        self.key = key
    }

    func canRead() async -> Bool { true }

    func readSlice(_ type: HealthDataType, from cursor: Date, window: DateInterval, rangeEnd: Date) async throws -> BackfillSlice {
        let limit = SyncLimits.maxRecordsPerSync(for: type)
        let inRange = times.enumerated().filter { $0.element >= cursor && $0.element < window.end }
        let slice = SyncLimits.sliceEnd(probedStartDates: Array(inRange.prefix(limit).map(\.element)), limit: limit, from: cursor, to: window.end)
        let records: [[String: Any]] = inRange.filter { $0.element < slice.end }.map {
            key == "steps"
                ? ["count": 10, "start_time": $0.element.iso8601String, "end_time": $0.element.iso8601String, "uuid": "st-\($0.offset)", "source": "iPhone"]
                : ["bpm": 70, "time": $0.element.iso8601String, "uuid": "hr-\($0.offset)", "source": "Apple Watch"]
        }
        return BackfillSlice(records: records.isEmpty ? [] : [(key, records)], end: slice.end, exact: slice.exact)
    }
}

private actor WholeSink: BackfillDelivering {
    private var sent: [Data] = []

    func deliver(_ body: Data, recordCount: Int) async -> Bool {
        sent.append(body)
        return true
    }

    func payloads() -> [[String: Any]] {
        sent.map { (try? JSONSerialization.jsonObject(with: $0) as? [String: Any]) ?? [:] }
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
        let inRange = times.enumerated().filter { $0.element >= cursor && $0.element < window.end }
        let slice = SyncLimits.sliceEnd(probedStartDates: Array(inRange.prefix(limit).map(\.element)), limit: limit, from: cursor, to: window.end)
        let records: [[String: Any]] = inRange.filter { $0.element < slice.end }.map {
            ["bpm": 70, "time": $0.element.iso8601String, "uuid": "hr-\($0.offset)", "source": "Apple Watch"]
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
