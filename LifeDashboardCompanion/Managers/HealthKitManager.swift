import Foundation
import HealthKit
import UIKit
import OSLog

/// @unchecked Sendable: HKHealthStore is thread-safe, `isAvailable` is set once in init,
/// and the @Published authorization status is only mutated via the @MainActor method.
final class HealthKitManager: ObservableObject, @unchecked Sendable {
    static let shared = HealthKitManager()

    let healthStore = HKHealthStore()
    private let logger = Logger(subsystem: "com.owen282000.lifedashboard", category: "HealthKit")

    @Published var authorizationStatus: [HealthDataType: HKAuthorizationStatus] = [:]
    @Published var isAvailable: Bool

    static let lookbackDays: Int = 7

    /// Result type indicating why data reading failed or returned empty
    enum ReadResult {
        case data([String: Any])
        case empty
        case protectedDataUnavailable
    }

    /// Payload fragments produced by reading a single data type, safe to move across
    /// the task group boundary. @unchecked Sendable: the values are JSON value types
    /// (String, Int, Double, arrays, dictionaries) freshly built per task.
    private struct PayloadFragments: @unchecked Sendable {
        let pairs: [(String, Any)]
    }

    private init() {
        self.isAvailable = HKHealthStore.isHealthDataAvailable()
    }

    // MARK: - Permissions

    func readTypesFor(_ types: Set<HealthDataType>) -> Set<HKObjectType> {
        var hkTypes = Set<HKObjectType>()
        for dataType in types {
            hkTypes.formUnion(dataType.hkReadTypes)
        }
        return hkTypes
    }

    func requestAuthorization(for types: Set<HealthDataType>) async throws {
        let readTypes = readTypesFor(types)
        guard !readTypes.isEmpty else { return }
        try await healthStore.requestAuthorization(toShare: [], read: readTypes)
        await updateAuthorizationStatus()
    }

    @MainActor
    func updateAuthorizationStatus() {
        var statuses: [HealthDataType: HKAuthorizationStatus] = [:]
        for dataType in HealthDataType.allCases {
            if let sampleType = dataType.hkSampleTypes.first {
                statuses[dataType] = healthStore.authorizationStatus(for: sampleType)
            } else {
                statuses[dataType] = .notDetermined
            }
        }
        self.authorizationStatus = statuses
    }

    /// Most recent heart rate sample, used by the About screen's beating-heart easter egg.
    func latestHeartRateBPM() async -> Int? {
        guard isAvailable else { return nil }
        return await withCheckedContinuation { continuation in
            let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)
            let query = HKSampleQuery(
                sampleType: HKQuantityType(.heartRate),
                predicate: nil,
                limit: 1,
                sortDescriptors: [sort]
            ) { _, samples, _ in
                let bpm = (samples?.first as? HKQuantitySample)
                    .map { Int($0.quantity.doubleValue(for: HKUnit.count().unitDivided(by: .minute()))) }
                continuation.resume(returning: bpm)
            }
            healthStore.execute(query)
        }
    }

    // MARK: - Data Reading

    func readHealthData(
        for enabledTypes: Set<HealthDataType>
    ) async throws -> [String: Any] {
        let startDate = Calendar.current.date(
            byAdding: .day,
            value: -HealthKitManager.lookbackDays,
            to: Date()
        )!
        let endDate = Date()

        // Run all type queries in parallel; a failure in one type only skips that type
        let results = await withTaskGroup(
            of: PayloadFragments?.self
        ) { group -> [String: Any] in
            for dataType in enabledTypes {
                group.addTask {
                    do {
                        guard let pairs = try await self.readDataForType(dataType, start: startDate, end: endDate) else {
                            return nil
                        }
                        return PayloadFragments(pairs: pairs)
                    } catch {
                        self.logger.error("Read failed for \(dataType.rawValue): \(error.localizedDescription)")
                        return nil
                    }
                }
            }

            var payload: [String: Any] = [:]
            for await result in group {
                for (key, value) in result?.pairs ?? [] {
                    payload[key] = value
                }
            }
            return payload
        }

        return results
    }

    // MARK: - Daily Totals

    /// Deduplicated daily step totals for the last `days` days including today, via
    /// HKStatisticsCollectionQuery which merges overlapping phone and watch samples
    /// instead of double counting. Returns oldest-first; empty when steps are unavailable.
    func readDailyStepTotals(days: Int) async -> [Int] {
        guard let stepType = HKObjectType.quantityType(forIdentifier: .stepCount) else { return [] }
        let calendar = Calendar.current
        let end = Date()
        let startOfToday = calendar.startOfDay(for: end)
        guard let start = calendar.date(byAdding: .day, value: -(days - 1), to: startOfToday) else { return [] }

        return await withCheckedContinuation { continuation in
            let query = HKStatisticsCollectionQuery(
                quantityType: stepType,
                quantitySamplePredicate: HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate),
                options: .cumulativeSum,
                anchorDate: startOfToday,
                intervalComponents: DateComponents(day: 1)
            )
            query.initialResultsHandler = { _, results, _ in
                var totals: [Int] = []
                results?.enumerateStatistics(from: start, to: end) { statistics, _ in
                    let value = statistics.sumQuantity()?.doubleValue(for: .count()) ?? 0
                    totals.append(Int(value))
                }
                continuation.resume(returning: totals)
            }
            self.healthStore.execute(query)
        }
    }

    // MARK: - Incremental (Anchor-Based) Reading

    /// Reads only new data since the last successful sync using HKAnchoredObjectQuery.
    /// Falls back to full 7-day read if no anchor exists (first sync).
    /// Returns `.protectedDataUnavailable` if the device is locked and data is encrypted.
    func readIncrementalData(
        for enabledTypes: Set<HealthDataType>
    ) async throws -> ReadResult {
        // Stap 5: Check if HealthKit data is accessible (device may be locked)
        let isProtected = await MainActor.run { UIApplication.shared.isProtectedDataAvailable }
        guard isProtected else {
            logger.info("Protected data unavailable (device locked) - skipping HealthKit read")
            return .protectedDataUnavailable
        }

        let prefs = PreferencesManager.shared

        let results = await withTaskGroup(
            of: PayloadFragments?.self
        ) { group -> [String: Any] in
            for dataType in enabledTypes {
                group.addTask {
                    do {
                        guard let pairs = try await self.readIncrementalDataForType(dataType, prefs: prefs) else {
                            return nil
                        }
                        return PayloadFragments(pairs: pairs)
                    } catch {
                        self.logger.error("Incremental read failed for \(dataType.rawValue): \(error.localizedDescription)")
                        return nil
                    }
                }
            }

            var payload: [String: Any] = [:]
            for await result in group {
                for (key, value) in result?.pairs ?? [] {
                    payload[key] = value
                }
            }
            return payload
        }

        return results.isEmpty ? .empty : .data(results)
    }

    /// Reads incremental data for a single type using HKAnchoredObjectQuery.
    ///
    /// New samples are found through the anchors, then the type is re-read by time from an
    /// hour before the earliest of them, which reuses the type-specific formatting. That read
    /// stops at the per-type cap (see `nextSlice`), and whatever lies past the cap is left to
    /// the catch-up cursor: the next sync continues there, so no record is skipped because
    /// the anchor already moved past it. Anchors and cursor are saved once the read is done.
    private func readIncrementalDataForType(
        _ dataType: HealthDataType,
        prefs: PreferencesManager
    ) async throws -> [(String, Any)]? {
        let now = Date()
        var readFrom = prefs.loadCatchUpCursor(for: dataType)
        var newAnchors: [(HKSampleType, HKQueryAnchor)] = []

        for sampleType in dataType.hkSampleTypes {
            if let anchor = prefs.loadAnchor(for: dataType, sampleType: sampleType) {
                let (earliestNew, newAnchor) = try await anchoredQuery(sampleType: sampleType, anchor: anchor)
                newAnchors.append((sampleType, newAnchor))
                if let earliest = earliestNew {
                    readFrom = min(readFrom ?? .distantFuture, earliest.addingTimeInterval(-3600))
                }
            } else {
                // First sync of this sample type: read the lookback window. The anchor is taken
                // before that read, so a sample written in between is read now or next time.
                newAnchors.append((sampleType, try await queryAnchor(for: sampleType)))
                let lookback = Calendar.current.date(byAdding: .day, value: -HealthKitManager.lookbackDays, to: now)!
                readFrom = min(readFrom ?? .distantFuture, lookback)
            }
        }

        var result: [(String, Any)]?
        var cursor: Date?
        if let start = readFrom, start < now {
            let slice = try await nextSlice(for: dataType, from: start, to: now)
            if !slice.exact {
                logger.error("More than the cap of \(dataType.rawValue) samples share \(start.iso8601String); the excess is not sent")
            }
            result = try await readDataForType(dataType, start: start, end: slice.end)
            cursor = slice.end < now ? slice.end : nil
        }

        for (sampleType, anchor) in newAnchors {
            prefs.saveAnchor(anchor, for: dataType, sampleType: sampleType)
        }
        prefs.saveCatchUpCursor(cursor, for: dataType)
        return result
    }

    /// Where a read of `dataType` from `start` has to stop to stay under its cap, so that
    /// nothing is cut off: a probe reads the start dates of the oldest samples of every
    /// sample type the payload type combines, and `SyncLimits.sliceEnd` picks the boundary.
    func nextSlice(for dataType: HealthDataType, from start: Date, to end: Date) async throws -> (end: Date, exact: Bool) {
        let limit = SyncLimits.maxRecordsPerSync(for: dataType)
        var startDates: [Date] = []
        for sampleType in dataType.hkSampleTypes {
            startDates += try await readSamples(type: sampleType, start: start, end: end, limit: limit).map(\.startDate)
        }
        return SyncLimits.sliceEnd(probedStartDates: startDates, limit: limit, from: start, to: end)
    }

    /// Samples per page of an anchored query. Only the earliest start date of a page is kept,
    /// so a type's whole history can go through without being held in memory at once.
    private static let anchorPageSize = 5000

    /// Walks the anchored query from `anchor` to the end of the store in pages, and returns
    /// the earliest start date among the samples added since `anchor` with the final anchor.
    private func anchoredQuery(
        sampleType: HKSampleType,
        anchor: HKQueryAnchor?
    ) async throws -> (earliest: Date?, anchor: HKQueryAnchor) {
        var current = anchor
        var earliest: Date?
        while true {
            let page = try await anchoredPage(sampleType: sampleType, anchor: current)
            if let date = page.earliest { earliest = min(earliest ?? date, date) }
            current = page.anchor
            if page.count < HealthKitManager.anchorPageSize { break }
        }
        return (earliest, current ?? HKQueryAnchor(fromValue: 0))
    }

    /// The current anchor of a sample type, for the first sync of it. A limit of 0 is
    /// HKObjectQueryNoLimit, which loaded the type's entire history at once; paging does not.
    private func queryAnchor(for sampleType: HKSampleType) async throws -> HKQueryAnchor {
        try await anchoredQuery(sampleType: sampleType, anchor: nil).anchor
    }

    private struct AnchoredPage {
        let earliest: Date?
        let count: Int
        let anchor: HKQueryAnchor?
    }

    private func anchoredPage(
        sampleType: HKSampleType,
        anchor: HKQueryAnchor?
    ) async throws -> AnchoredPage {
        try await withCheckedThrowingContinuation { continuation in
            let query = HKAnchoredObjectQuery(
                type: sampleType,
                predicate: nil,
                anchor: anchor,
                limit: HealthKitManager.anchorPageSize
            ) { _, addedSamples, _, newAnchor, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                let samples = addedSamples ?? []
                continuation.resume(returning: AnchoredPage(
                    earliest: samples.map(\.startDate).min(),
                    count: samples.count,
                    anchor: newAnchor ?? anchor
                ))
            }
            healthStore.execute(query)
        }
    }

    /// Adds the stable HealthKit UUID and the writing app/device to a payload record,
    /// so servers can deduplicate re-sent records and trace their origin.
    private func record(_ fields: [String: Any], from sample: HKSample) -> [String: Any] {
        var record = fields
        record["uuid"] = sample.uuid.uuidString
        record["source"] = sample.sourceRevision.source.name
        return record
    }

    /// Reads data for a single HealthDataType. Returns (payloadKey, data) pairs or nil if empty.
    /// Most types produce one pair; menstruation produces both flow records and derived periods.
    /// Reads are capped oldest-first per type (see SyncLimits) to bound payload size.
    private func readDataForType(
        _ dataType: HealthDataType,
        start: Date,
        end: Date
    ) async throws -> [(String, Any)]? {
        let limit = SyncLimits.maxRecordsPerSync(for: dataType)
        switch dataType {
        case .steps:
            let records = try await readQuantitySamples(
                type: HKQuantityType(.stepCount),
                start: start, end: end,
                limit: limit
            )
            let mapped = records.map { sample -> [String: Any] in
                record([
                    "count": Int(sample.quantity.doubleValue(for: .count())),
                    "start_time": sample.startDate.iso8601String,
                    "end_time": sample.endDate.iso8601String
                ], from: sample)
            }
            return mapped.isEmpty ? nil : [("steps", mapped)]

        case .distance:
            let records = try await readQuantitySamples(
                type: HKQuantityType(.distanceWalkingRunning),
                start: start, end: end,
                limit: limit
            )
            let mapped = records.map { sample -> [String: Any] in
                record([
                    "meters": sample.quantity.doubleValue(for: .meter()),
                    "start_time": sample.startDate.iso8601String,
                    "end_time": sample.endDate.iso8601String
                ], from: sample)
            }
            return mapped.isEmpty ? nil : [("distance", mapped)]

        case .activeCalories:
            let records = try await readQuantitySamples(
                type: HKQuantityType(.activeEnergyBurned),
                start: start, end: end,
                limit: limit
            )
            let mapped = records.map { sample -> [String: Any] in
                record([
                    "calories": sample.quantity.doubleValue(for: .kilocalorie()),
                    "start_time": sample.startDate.iso8601String,
                    "end_time": sample.endDate.iso8601String
                ], from: sample)
            }
            return mapped.isEmpty ? nil : [("active_calories", mapped)]

        case .totalCalories:
            async let activeRecords = readQuantitySamples(
                type: HKQuantityType(.activeEnergyBurned),
                start: start, end: end,
                limit: limit
            )
            async let basalRecords = readQuantitySamples(
                type: HKQuantityType(.basalEnergyBurned),
                start: start, end: end,
                limit: limit
            )
            let combined = try await SyncLimits.capOldestFirst(
                activeRecords + basalRecords,
                limit: limit,
                timeOf: { $0.startDate }
            )
            let mapped = combined.map { sample -> [String: Any] in
                record([
                    "calories": sample.quantity.doubleValue(for: .kilocalorie()),
                    "start_time": sample.startDate.iso8601String,
                    "end_time": sample.endDate.iso8601String
                ], from: sample)
            }
            return mapped.isEmpty ? nil : [("total_calories", mapped)]

        case .weight:
            let records = try await readQuantitySamples(
                type: HKQuantityType(.bodyMass),
                start: start, end: end,
                limit: limit
            )
            let mapped = records.map { sample -> [String: Any] in
                record([
                    "kilograms": sample.quantity.doubleValue(for: .gramUnit(with: .kilo)),
                    "time": sample.startDate.iso8601String
                ], from: sample)
            }
            return mapped.isEmpty ? nil : [("weight", mapped)]

        case .height:
            let records = try await readQuantitySamples(
                type: HKQuantityType(.height),
                start: start, end: end,
                limit: limit
            )
            let mapped = records.map { sample -> [String: Any] in
                record([
                    "meters": sample.quantity.doubleValue(for: .meter()),
                    "time": sample.startDate.iso8601String
                ], from: sample)
            }
            return mapped.isEmpty ? nil : [("height", mapped)]

        case .heartRate:
            let records = try await readQuantitySamples(
                type: HKQuantityType(.heartRate),
                start: start, end: end,
                limit: limit
            )
            let mapped = records.map { sample -> [String: Any] in
                record([
                    "bpm": Int(sample.quantity.doubleValue(for: HKUnit.count().unitDivided(by: .minute()))),
                    "time": sample.startDate.iso8601String
                ], from: sample)
            }
            return mapped.isEmpty ? nil : [("heart_rate", mapped)]

        case .restingHeartRate:
            let records = try await readQuantitySamples(
                type: HKQuantityType(.restingHeartRate),
                start: start, end: end,
                limit: limit
            )
            let mapped = records.map { sample -> [String: Any] in
                record([
                    "bpm": Int(sample.quantity.doubleValue(for: HKUnit.count().unitDivided(by: .minute()))),
                    "time": sample.startDate.iso8601String
                ], from: sample)
            }
            return mapped.isEmpty ? nil : [("resting_heart_rate", mapped)]

        case .heartRateVariability:
            let records = try await readQuantitySamples(
                type: HKQuantityType(.heartRateVariabilitySDNN),
                start: start, end: end,
                limit: limit
            )
            let mapped = records.map { sample -> [String: Any] in
                record([
                    "heart_rate_variability_millis": sample.quantity.doubleValue(for: .secondUnit(with: .milli)),
                    "time": sample.startDate.iso8601String
                ], from: sample)
            }
            return mapped.isEmpty ? nil : [("heart_rate_variability", mapped)]

        case .bloodPressure:
            async let systolicRecords = readQuantitySamples(
                type: HKQuantityType(.bloodPressureSystolic),
                start: start, end: end,
                limit: limit
            )
            async let diastolicRecords = readQuantitySamples(
                type: HKQuantityType(.bloodPressureDiastolic),
                start: start, end: end,
                limit: limit
            )
            let systolic = try await systolicRecords
            let diastolic = try await diastolicRecords
            let mmHg = HKUnit.millimeterOfMercury()
            var mapped: [[String: Any]] = []
            for systolicSample in systolic {
                let matchingDiastolic = diastolic.first {
                    abs($0.startDate.timeIntervalSince(systolicSample.startDate)) < 1
                }
                var fields: [String: Any] = [
                    "systolic": systolicSample.quantity.doubleValue(for: mmHg),
                    "time": systolicSample.startDate.iso8601String
                ]
                if let diastolicSample = matchingDiastolic {
                    fields["diastolic"] = diastolicSample.quantity.doubleValue(for: mmHg)
                }
                mapped.append(record(fields, from: systolicSample))
            }
            return mapped.isEmpty ? nil : [("blood_pressure", mapped)]

        case .bloodGlucose:
            let records = try await readQuantitySamples(
                type: HKQuantityType(.bloodGlucose),
                start: start, end: end,
                limit: limit
            )
            let mapped = records.map { sample -> [String: Any] in
                record([
                    "mmol_per_liter": sample.quantity.doubleValue(
                        for: HKUnit.moleUnit(with: .milli, molarMass: HKUnitMolarMassBloodGlucose).unitDivided(by: .liter())
                    ),
                    "time": sample.startDate.iso8601String
                ], from: sample)
            }
            return mapped.isEmpty ? nil : [("blood_glucose", mapped)]

        case .oxygenSaturation:
            let records = try await readQuantitySamples(
                type: HKQuantityType(.oxygenSaturation),
                start: start, end: end,
                limit: limit
            )
            let mapped = records.map { sample -> [String: Any] in
                record([
                    "percentage": sample.quantity.doubleValue(for: .percent()) * 100,
                    "time": sample.startDate.iso8601String
                ], from: sample)
            }
            return mapped.isEmpty ? nil : [("oxygen_saturation", mapped)]

        case .bodyTemperature:
            let records = try await readQuantitySamples(
                type: HKQuantityType(.bodyTemperature),
                start: start, end: end,
                limit: limit
            )
            let mapped = records.map { sample -> [String: Any] in
                record([
                    "celsius": sample.quantity.doubleValue(for: .degreeCelsius()),
                    "time": sample.startDate.iso8601String
                ], from: sample)
            }
            return mapped.isEmpty ? nil : [("body_temperature", mapped)]

        case .respiratoryRate:
            let records = try await readQuantitySamples(
                type: HKQuantityType(.respiratoryRate),
                start: start, end: end,
                limit: limit
            )
            let mapped = records.map { sample -> [String: Any] in
                record([
                    "rate": sample.quantity.doubleValue(for: HKUnit.count().unitDivided(by: .minute())),
                    "time": sample.startDate.iso8601String
                ], from: sample)
            }
            return mapped.isEmpty ? nil : [("respiratory_rate", mapped)]

        case .bodyFat:
            let records = try await readQuantitySamples(
                type: HKQuantityType(.bodyFatPercentage),
                start: start, end: end,
                limit: limit
            )
            let mapped = records.map { sample -> [String: Any] in
                record([
                    "percentage": sample.quantity.doubleValue(for: .percent()) * 100,
                    "time": sample.startDate.iso8601String
                ], from: sample)
            }
            return mapped.isEmpty ? nil : [("body_fat", mapped)]

        case .leanBodyMass:
            let records = try await readQuantitySamples(
                type: HKQuantityType(.leanBodyMass),
                start: start, end: end,
                limit: limit
            )
            let mapped = records.map { sample -> [String: Any] in
                record([
                    "kilograms": sample.quantity.doubleValue(for: .gramUnit(with: .kilo)),
                    "time": sample.startDate.iso8601String
                ], from: sample)
            }
            return mapped.isEmpty ? nil : [("lean_body_mass", mapped)]

        case .sleep:
            let sleepData = try await readSleepData(start: start, end: end, limit: limit)
            return sleepData.isEmpty ? nil : [("sleep", sleepData)]

        case .exercise:
            let workouts = try await readWorkouts(start: start, end: end, limit: limit)
            return workouts.isEmpty ? nil : [("exercise", workouts)]

        case .hydration:
            let records = try await readQuantitySamples(
                type: HKQuantityType(.dietaryWater),
                start: start, end: end,
                limit: limit
            )
            let mapped = records.map { sample -> [String: Any] in
                record([
                    "liters": sample.quantity.doubleValue(for: .liter()),
                    "start_time": sample.startDate.iso8601String,
                    "end_time": sample.endDate.iso8601String
                ], from: sample)
            }
            return mapped.isEmpty ? nil : [("hydration", mapped)]

        case .nutrition:
            let nutritionData = try await readNutritionData(start: start, end: end, limit: limit)
            return nutritionData.isEmpty ? nil : [("nutrition", nutritionData)]

        case .mindfulness:
            let records = try await readCategorySamples(
                type: HKCategoryType(.mindfulSession),
                start: start, end: end,
                limit: limit
            )
            let mapped = records.map { sample -> [String: Any] in
                let duration = sample.endDate.timeIntervalSince(sample.startDate)
                return record([
                    "start_time": sample.startDate.iso8601String,
                    "end_time": sample.endDate.iso8601String,
                    "duration_seconds": Int(duration)
                ], from: sample)
            }
            return mapped.isEmpty ? nil : [("mindfulness", mapped)]

        case .menstruation:
            let records = try await readCategorySamples(
                type: HKCategoryType(.menstrualFlow),
                start: start, end: end,
                limit: limit
            )
            let flowSamples = records.compactMap { sample -> (HKCategorySample, String)? in
                guard let value = HKCategoryValueMenstrualFlow(rawValue: sample.value) else { return nil }
                switch value {
                case .light: return (sample, "light")
                case .medium: return (sample, "medium")
                case .heavy: return (sample, "heavy")
                case .unspecified: return (sample, "unknown")
                default: return nil  // .none means no bleeding: skip
                }
            }
            let mapped = flowSamples.map { sample, flow in
                record([
                    "flow": flow,
                    "time": sample.startDate.iso8601String
                ], from: sample)
            }
            guard !mapped.isEmpty else { return nil }

            // HealthKit has no period record type; derive periods from consecutive flow
            // days so the payload matches the Android app's menstruation_period records.
            let periods = MenstruationPeriodBuilder.periods(
                from: flowSamples.map { FlowSample(start: $0.0.startDate, end: $0.0.endDate) }
            )
            return [("menstruation_flow", mapped), ("menstruation_period", periods)]

        case .vo2Max:
            let records = try await readQuantitySamples(
                type: HKQuantityType(.vo2Max),
                start: start, end: end,
                limit: limit
            )
            let mapped = records.map { record(HealthRecordMapping.vo2MaxFields($0), from: $0) }
            return mapped.isEmpty ? nil : [(dataType.countedPayloadKey, mapped)]

        case .basalBodyTemperature:
            let records = try await readQuantitySamples(
                type: HKQuantityType(.basalBodyTemperature),
                start: start, end: end,
                limit: limit
            )
            let mapped = records.map { record(HealthRecordMapping.basalBodyTemperatureFields($0), from: $0) }
            return mapped.isEmpty ? nil : [(dataType.countedPayloadKey, mapped)]

        case .intermenstrualBleeding:
            let records = try await readCategorySamples(
                type: HKCategoryType(.intermenstrualBleeding),
                start: start, end: end,
                limit: limit
            )
            let mapped = records.map { record(HealthRecordMapping.intermenstrualBleedingFields($0), from: $0) }
            return mapped.isEmpty ? nil : [(dataType.countedPayloadKey, mapped)]

        case .ovulationTest:
            let records = try await readCategorySamples(
                type: HKCategoryType(.ovulationTestResult),
                start: start, end: end,
                limit: limit
            )
            let mapped = records.map { record(HealthRecordMapping.ovulationTestFields($0), from: $0) }
            return mapped.isEmpty ? nil : [(dataType.countedPayloadKey, mapped)]

        case .cervicalMucus:
            let records = try await readCategorySamples(
                type: HKCategoryType(.cervicalMucusQuality),
                start: start, end: end,
                limit: limit
            )
            let mapped = records.map { record(HealthRecordMapping.cervicalMucusFields($0), from: $0) }
            return mapped.isEmpty ? nil : [(dataType.countedPayloadKey, mapped)]

        case .sexualActivity:
            let records = try await readCategorySamples(
                type: HKCategoryType(.sexualActivity),
                start: start, end: end,
                limit: limit
            )
            let mapped = records.map { record(HealthRecordMapping.sexualActivityFields($0), from: $0) }
            return mapped.isEmpty ? nil : [(dataType.countedPayloadKey, mapped)]
        }
    }

    // MARK: - Query Helpers

    /// Reads at most `limit` samples of any type in `[start, end)`, oldest first.
    private func readSamples(
        type: HKSampleType,
        start: Date,
        end: Date,
        limit: Int
    ) async throws -> [HKSample] {
        try await withCheckedThrowingContinuation { continuation in
            let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
            let sortDescriptor = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)

            let query = HKSampleQuery(
                sampleType: type,
                predicate: predicate,
                limit: limit,
                sortDescriptors: [sortDescriptor]
            ) { _, samples, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: samples ?? [])
            }
            healthStore.execute(query)
        }
    }

    /// Reads at most `limit` samples, oldest first (ascending sort + query limit), so payload
    /// size stays bounded and later syncs catch up without skipping records.
    private func readQuantitySamples(
        type: HKQuantityType,
        start: Date,
        end: Date,
        limit: Int
    ) async throws -> [HKQuantitySample] {
        try await withCheckedThrowingContinuation { continuation in
            let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
            let sortDescriptor = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)

            let query = HKSampleQuery(
                sampleType: type,
                predicate: predicate,
                limit: limit,
                sortDescriptors: [sortDescriptor]
            ) { _, samples, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: (samples as? [HKQuantitySample]) ?? [])
            }
            healthStore.execute(query)
        }
    }

    private func readCategorySamples(
        type: HKCategoryType,
        start: Date,
        end: Date,
        limit: Int
    ) async throws -> [HKCategorySample] {
        try await withCheckedThrowingContinuation { continuation in
            let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
            let sortDescriptor = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)

            let query = HKSampleQuery(
                sampleType: type,
                predicate: predicate,
                limit: limit,
                sortDescriptors: [sortDescriptor]
            ) { _, samples, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: (samples as? [HKCategorySample]) ?? [])
            }
            healthStore.execute(query)
        }
    }

    private func readSleepData(start: Date, end: Date, limit: Int) async throws -> [[String: Any]] {
        let samples = try await readCategorySamples(
            type: HKCategoryType(.sleepAnalysis),
            start: start, end: end,
            limit: limit
        )

        // Stage values match the Android companion app so both can feed the same backend.
        let stageSamples = samples.compactMap { sample -> SleepStageSample? in
            guard let value = HKCategoryValueSleepAnalysis(rawValue: sample.value) else { return nil }
            let stage: String
            switch value {
            case .inBed: stage = "in_bed"  // Container only, not a real stage
            case .asleepUnspecified: stage = "sleeping"
            case .asleepCore: stage = "light"
            case .asleepDeep: stage = "deep"
            case .asleepREM: stage = "rem"
            case .awake: stage = "awake"
            @unknown default: stage = "unknown"
            }
            return SleepStageSample(
                stage: stage,
                start: sample.startDate,
                end: sample.endDate,
                uuid: sample.uuid.uuidString,
                source: sample.sourceRevision.source.name
            )
        }

        return SleepSessionBuilder.sessions(from: stageSamples)
    }

    private func readWorkouts(start: Date, end: Date, limit: Int) async throws -> [[String: Any]] {
        let workouts: [HKWorkout] = try await withCheckedThrowingContinuation { continuation in
            let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
            let sortDescriptor = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)

            let query = HKSampleQuery(
                sampleType: HKWorkoutType.workoutType(),
                predicate: predicate,
                limit: limit,
                sortDescriptors: [sortDescriptor]
            ) { _, samples, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: (samples as? [HKWorkout]) ?? [])
            }
            healthStore.execute(query)
        }

        return workouts.map { workout in
            record([
                "type": workout.workoutActivityType.name,
                "start_time": workout.startDate.iso8601String,
                "end_time": workout.endDate.iso8601String,
                "duration_seconds": Int(workout.duration)
            ], from: workout)
        }
    }

    private func readNutritionData(start: Date, end: Date, limit: Int) async throws -> [[String: Any]] {
        let calorieRecords = try await readQuantitySamples(
            type: HKQuantityType(.dietaryEnergyConsumed),
            start: start, end: end,
            limit: limit
        )
        let proteinRecords = try await readQuantitySamples(
            type: HKQuantityType(.dietaryProtein),
            start: start, end: end,
            limit: limit
        )
        let carbRecords = try await readQuantitySamples(
            type: HKQuantityType(.dietaryCarbohydrates),
            start: start, end: end,
            limit: limit
        )
        let fatRecords = try await readQuantitySamples(
            type: HKQuantityType(.dietaryFatTotal),
            start: start, end: end,
            limit: limit
        )

        // Combine by matching timestamps
        var mapped: [[String: Any]] = calorieRecords.map { sample -> [String: Any] in
            var fields: [String: Any] = [
                "calories": sample.quantity.doubleValue(for: .kilocalorie()),
                "start_time": sample.startDate.iso8601String,
                "end_time": sample.endDate.iso8601String
            ]
            if let protein = proteinRecords.first(where: { abs($0.startDate.timeIntervalSince(sample.startDate)) < 1 }) {
                fields["protein_grams"] = protein.quantity.doubleValue(for: .gram())
            }
            if let carb = carbRecords.first(where: { abs($0.startDate.timeIntervalSince(sample.startDate)) < 1 }) {
                fields["carbs_grams"] = carb.quantity.doubleValue(for: .gram())
            }
            if let fat = fatRecords.first(where: { abs($0.startDate.timeIntervalSince(sample.startDate)) < 1 }) {
                fields["fat_grams"] = fat.quantity.doubleValue(for: .gram())
            }
            return record(fields, from: sample)
        }

        // Also include standalone protein/carb/fat records not matched to calories
        for protein in proteinRecords
        where !calorieRecords.contains(where: { abs($0.startDate.timeIntervalSince(protein.startDate)) < 1 }) {
            mapped.append(record([
                "protein_grams": protein.quantity.doubleValue(for: .gram()),
                "start_time": protein.startDate.iso8601String,
                "end_time": protein.endDate.iso8601String
            ], from: protein))
        }

        return mapped
    }
}

// MARK: - Extensions

extension Date {
    // ISO8601DateFormatter is documented as thread-safe, unlike DateFormatter
    nonisolated(unsafe) private static let iso8601Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        return formatter
    }()

    var iso8601String: String {
        Date.iso8601Formatter.string(from: self)
    }
}

extension HKWorkoutActivityType {
    var name: String {
        switch self {
        case .americanFootball: return "american_football"
        case .archery: return "archery"
        case .australianFootball: return "australian_football"
        case .badminton: return "badminton"
        case .baseball: return "baseball"
        case .basketball: return "basketball"
        case .bowling: return "bowling"
        case .boxing: return "boxing"
        case .climbing: return "climbing"
        case .cricket: return "cricket"
        case .crossTraining: return "cross_training"
        case .curling: return "curling"
        case .cycling: return "cycling"
        case .dance: return "dance"
        case .elliptical: return "elliptical"
        case .equestrianSports: return "equestrian_sports"
        case .fencing: return "fencing"
        case .fishing: return "fishing"
        case .functionalStrengthTraining: return "functional_strength_training"
        case .golf: return "golf"
        case .gymnastics: return "gymnastics"
        case .handball: return "handball"
        case .hiking: return "hiking"
        case .hockey: return "hockey"
        case .hunting: return "hunting"
        case .lacrosse: return "lacrosse"
        case .martialArts: return "martial_arts"
        case .mindAndBody: return "mind_and_body"
        case .paddleSports: return "paddle_sports"
        case .play: return "play"
        case .preparationAndRecovery: return "preparation_and_recovery"
        case .racquetball: return "racquetball"
        case .rowing: return "rowing"
        case .rugby: return "rugby"
        case .running: return "running"
        case .sailing: return "sailing"
        case .skatingSports: return "skating_sports"
        case .snowSports: return "snow_sports"
        case .soccer: return "soccer"
        case .softball: return "softball"
        case .squash: return "squash"
        case .stairClimbing: return "stair_climbing"
        case .surfingSports: return "surfing_sports"
        case .swimming: return "swimming"
        case .tableTennis: return "table_tennis"
        case .tennis: return "tennis"
        case .trackAndField: return "track_and_field"
        case .traditionalStrengthTraining: return "traditional_strength_training"
        case .volleyball: return "volleyball"
        case .walking: return "walking"
        case .waterFitness: return "water_fitness"
        case .waterPolo: return "water_polo"
        case .waterSports: return "water_sports"
        case .wrestling: return "wrestling"
        case .yoga: return "yoga"
        case .pilates: return "pilates"
        case .highIntensityIntervalTraining: return "hiit"
        case .coreTraining: return "core_training"
        case .flexibility: return "flexibility"
        case .cooldown: return "cooldown"
        default: return "other"
        }
    }
}
